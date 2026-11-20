use crate::artwork_image::{self, MipChain};
use crate::artwork_search::{self, Candidate, Request};
use crate::db::Db;
use crate::library::{Album, Track};
use crate::local_artwork::{self, LocalCover, Origin};
use crate::ui::artwork_crop::{preview_area, ArtworkSource, CropView, ThumbArea, KEY_ZOOM_FACTOR};
use crate::ui::Ui;
use adw::prelude::*;
use flaccy_shared::{artwork_local, playlist_cover};
use gtk::{gdk, gio, glib};
use image::RgbaImage;
use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::path::PathBuf;
use std::rc::Rc;

const SOFT_WARNING: &str = "Low resolution — this will look soft on large displays";
const TILE_SIDE: i32 = 80;
const LOCAL_THUMBNAIL: u32 = 192;
const ONLINE_THUMBNAIL_BYTES: u64 = 6 * 1024 * 1024;
const THUMBNAIL_WORKERS: usize = 4;

/// Where a picture for the editor comes from, before it has been read.
#[derive(Clone, Debug)]
pub enum Payload {
    Path(PathBuf),
    Bytes(Vec<u8>),
    Url(String),
}

impl Payload {
    fn bytes(self) -> Result<Vec<u8>, String> {
        match self {
            Payload::Bytes(bytes) => Ok(bytes),
            Payload::Path(path) => {
                let length = std::fs::metadata(&path)
                    .map_err(|err| err.to_string())?
                    .len();
                if length > artwork_local::MAXIMUM_FILE_BYTES {
                    return Err("That image is larger than 25 MB.".to_string());
                }
                std::fs::read(&path).map_err(|err| err.to_string())
            }
            Payload::Url(url) => {
                artwork_search::fetch_bytes(&url, true, artwork_search::MAXIMUM_BODY_BYTES)
                    .map_err(|err| err.to_string())
            }
        }
    }
}

/// What a clipboard or a drag carried as text: a link, a `file://` URI or a
/// path that exists. Only the first line counts; `text/uri-list` comments are
/// skipped.
pub fn payload_from_text(text: &str) -> Option<Payload> {
    let line = text
        .lines()
        .map(str::trim)
        .find(|line| !line.is_empty() && !line.starts_with('#'))?;
    if line.starts_with("http://") || line.starts_with("https://") {
        return Some(Payload::Url(line.to_string()));
    }
    if line.starts_with("file://") {
        return glib::filename_from_uri(line)
            .ok()
            .map(|(path, _)| Payload::Path(path));
    }
    let path = PathBuf::from(line);
    (path.is_absolute() && path.is_file()).then_some(Payload::Path(path))
}

/// The picture a dropped or pasted value carries: a file, raw image data or
/// text naming one.
pub fn payload_from_value(value: &glib::Value) -> Option<Payload> {
    if let Ok(list) = value.get::<gdk::FileList>() {
        return list
            .files()
            .into_iter()
            .find_map(|file| file.path())
            .map(Payload::Path);
    }
    if let Ok(texture) = value.get::<gdk::Texture>() {
        return Some(Payload::Bytes(texture.save_to_png_bytes().to_vec()));
    }
    if let Ok(file) = value.get::<gio::File>() {
        return file.path().map(Payload::Path);
    }
    if let Ok(text) = value.get::<String>() {
        return payload_from_text(&text);
    }
    None
}

/// Runs `work` off the main thread and hands its answer back on it.
fn spawn_work<T: Send + 'static>(
    name: &str,
    work: impl FnOnce() -> T + Send + 'static,
    done: impl FnOnce(T) + 'static,
) {
    let (tx, rx) = async_channel::bounded(1);
    std::thread::Builder::new()
        .name(name.into())
        .spawn(move || {
            let _ = tx.send_blocking(work());
        })
        .ok();
    glib::spawn_future_local(async move {
        if let Ok(answer) = rx.recv().await {
            done(answer);
        }
    });
}

/// Runs `work` off the main thread, which sends results as it finds them; each
/// arrives on the main thread in order.
fn spawn_stream<T: Send + 'static>(
    name: &str,
    work: impl FnOnce(async_channel::Sender<T>) + Send + 'static,
    each: impl Fn(T) + 'static,
) {
    let (tx, rx) = async_channel::unbounded();
    std::thread::Builder::new()
        .name(name.into())
        .spawn(move || work(tx))
        .ok();
    glib::spawn_future_local(async move {
        while let Ok(item) = rx.recv().await {
            each(item);
        }
    });
}

#[derive(Clone)]
struct Tile {
    button: gtk::Button,
    art: ThumbArea,
}

struct Loaded {
    chain: MipChain,
}

enum LoadFailure {
    Unreadable,
    Message(String),
}

fn decode_payload(payload: Payload) -> Result<Loaded, LoadFailure> {
    let bytes = payload.bytes().map_err(LoadFailure::Message)?;
    let image = artwork_image::decode(&bytes, artwork_image::DECODE_LIMIT)
        .ok_or(LoadFailure::Unreadable)?;
    Ok(Loaded {
        chain: MipChain::new(image),
    })
}

struct LoadRequest {
    payload: Payload,
    label: String,
    tile: Option<String>,
    failure: &'static str,
    user_initiated: bool,
}

/// What the editor is choosing a cover for: a release or a playlist. A
/// playlist is addressed in the artwork cache by the reserved key
/// `playlist_cover` defines, so the cache, the decode worker and the repaint
/// event serve it exactly as they serve an album.
#[derive(Clone)]
pub enum Subject {
    Album(Album),
    Playlist {
        id: i64,
        name: String,
        tracks: Vec<Track>,
    },
}

impl Subject {
    fn key(&self) -> String {
        match self {
            Subject::Album(album) => album.key(),
            Subject::Playlist { id, .. } => playlist_cover::title_for(*id),
        }
    }

    fn title(&self) -> &str {
        match self {
            Subject::Album(album) => &album.title,
            Subject::Playlist { name, .. } => name,
        }
    }

    fn credit(&self) -> &str {
        match self {
            Subject::Album(album) => &album.artist,
            Subject::Playlist { .. } => "",
        }
    }

    fn is_playlist(&self) -> bool {
        matches!(self, Subject::Playlist { .. })
    }

    fn subtitle(&self) -> String {
        match self {
            Subject::Album(album) => format!("{} · {}", album.title, album.artist),
            Subject::Playlist { name, tracks, .. } => {
                format!("{name} · {}", track_count_label(tracks.len()))
            }
        }
    }

    fn artwork_keys(&self) -> Vec<(String, String)> {
        match self {
            Subject::Album(album) => album.artwork_keys(),
            Subject::Playlist { id, .. } => {
                vec![(playlist_cover::title_for(*id), playlist_cover::ARTIST.to_string())]
            }
        }
    }

    fn has_custom_cover(&self, db: &Db) -> bool {
        match self {
            Subject::Album(album) => db.has_custom_cover(&album.artwork_keys()),
            Subject::Playlist { id, .. } => db.has_playlist_cover(*id),
        }
    }

    fn current_cover(&self, db: &Db) -> Option<Vec<u8>> {
        match self {
            Subject::Album(album) => db.fetch_album_artwork(&album.title, &album.artist),
            Subject::Playlist { id, .. } => db.playlist_cover(*id),
        }
    }

    fn save_cover(&self, db: &Db, jpeg: &[u8]) -> Result<(), rusqlite::Error> {
        match self {
            Subject::Album(album) => db.set_custom_cover(&album.artwork_keys(), jpeg),
            Subject::Playlist { id, .. } => db.set_playlist_cover(*id, jpeg),
        }
    }

    fn clear_cover(&self, db: &Db) -> Result<(), rusqlite::Error> {
        match self {
            Subject::Album(album) => db.clear_custom_cover(&album.artwork_keys()),
            Subject::Playlist { id, .. } => db.clear_playlist_cover(*id),
        }
    }

    fn default_query(&self) -> String {
        match self {
            Subject::Album(album) => artwork_search::default_query(&album.title, &album.artist),
            Subject::Playlist { .. } => String::new(),
        }
    }

    fn reset_label(&self) -> &'static str {
        if self.is_playlist() {
            "Use Automatic Cover"
        } else {
            "Use Original Artwork"
        }
    }

    fn reset_heading(&self) -> &'static str {
        if self.is_playlist() {
            "Use the automatic cover?"
        } else {
            "Use the original artwork?"
        }
    }

    fn reset_body(&self) -> &'static str {
        if self.is_playlist() {
            "Your chosen cover will be removed and the playlist shows a mosaic of its albums again."
        } else {
            "Your chosen cover will be removed and the artwork from the music files is used again."
        }
    }

    fn reset_toast(&self) -> &'static str {
        if self.is_playlist() {
            "Automatic cover restored"
        } else {
            "Original artwork restored"
        }
    }

    fn shelf_title(&self) -> &'static str {
        if self.is_playlist() {
            "From This Playlist"
        } else {
            "In Your Files"
        }
    }

    fn search_placeholder(&self) -> &'static str {
        if self.is_playlist() {
            "Search for cover art"
        } else {
            "Artist and album"
        }
    }

    fn previews(&self) -> Vec<(i32, f64, &'static str)> {
        if self.is_playlist() {
            vec![(120, 14.0, "Playlist"), (48, 8.0, "List")]
        } else {
            vec![(120, 14.0, "Album"), (48, 8.0, "List"), (32, 6.0, "Player")]
        }
    }

    fn announce_change(&self, core: &crate::app::AppCore) {
        core.album_artwork_changed(&self.artwork_keys());
    }
}

fn track_count_label(count: usize) -> String {
    format!("{count} track{}", if count == 1 { "" } else { "s" })
}

pub struct Editor {
    ui: Rc<Ui>,
    subject: Subject,
    dialog: adw::Dialog,
    crop: Rc<CropView>,
    backdrop: gtk::DrawingArea,
    spinner: gtk::Spinner,
    empty: gtk::Label,
    info: gtk::Label,
    soft: gtk::Box,
    zoom: gtk::Scale,
    zoom_syncing: Cell<bool>,
    save: gtk::Button,
    reset: gtk::Button,
    paste: gtk::Button,
    files_section: gtk::Box,
    files_flow: gtk::FlowBox,
    online_flow: gtk::FlowBox,
    online_status: gtk::Label,
    online_spinner: gtk::Spinner,
    search_entry: gtk::Entry,
    tiles: RefCell<HashMap<String, Tile>>,
    selected_tile: RefCell<Option<String>>,
    source_label: RefCell<String>,
    replaced: Cell<bool>,
    has_custom: Cell<bool>,
    loaded_once: Cell<bool>,
    load_token: Cell<u64>,
    search_token: Cell<u64>,
    busy_saving: Cell<bool>,
    finished: Cell<bool>,
    clipboard_handler: RefCell<Option<glib::SignalHandlerId>>,
}

thread_local! {
    static CURRENT: RefCell<Option<Rc<Editor>>> = const { RefCell::new(None) };
}

/// Opens the editor for an album, optionally with a picture already loaded and
/// framed (a drop on a cover). While one is open, another request reuses it.
pub fn present(ui: &Rc<Ui>, album: &Album, preload: Option<Payload>) -> Rc<Editor> {
    present_subject(ui, Subject::Album(album.clone()), preload)
}

/// Opens the editor for a playlist's cover, resolving its tracks against the
/// live library so the shelf and the header know what the playlist holds.
pub fn present_playlist(ui: &Rc<Ui>, playlist_id: i64, preload: Option<Payload>) -> Rc<Editor> {
    present_subject(ui, playlist_subject(ui, playlist_id), preload)
}

pub fn playlist_subject(ui: &Rc<Ui>, playlist_id: i64) -> Subject {
    let name = ui
        .core
        .db
        .playlist_name(playlist_id)
        .unwrap_or_else(|| "Playlist".to_string());
    let library = ui.core.library.borrow().clone();
    let by_rel_path: HashMap<&str, &Track> = library
        .tracks
        .iter()
        .map(|track| (track.rel_path.as_str(), track))
        .collect();
    let tracks = ui
        .core
        .db
        .playlist_tracks(playlist_id)
        .into_iter()
        .filter_map(|row| by_rel_path.get(row.rel_path.as_str()).map(|track| (*track).clone()))
        .collect();
    Subject::Playlist {
        id: playlist_id,
        name,
        tracks,
    }
}

pub fn present_subject(ui: &Rc<Ui>, subject: Subject, preload: Option<Payload>) -> Rc<Editor> {
    if let Some(open) = CURRENT.with(|slot| slot.borrow().clone()) {
        if open.subject.key() == subject.key() {
            open.dialog.present(Some(&ui.window));
            if let Some(payload) = preload {
                open.load(LoadRequest {
                    payload,
                    label: "Dropped image".to_string(),
                    tile: None,
                    failure: "That file couldn't be read as an image.",
                    user_initiated: true,
                });
            }
            return open;
        }
    }
    let editor = Editor::build(ui, &subject);
    CURRENT.with(|slot| *slot.borrow_mut() = Some(Rc::clone(&editor)));
    editor.present(preload);
    editor
}

impl Editor {
    fn build(ui: &Rc<Ui>, subject: &Subject) -> Rc<Self> {
        let has_custom = subject.has_custom_cover(&ui.core.db);
        let crop = CropView::new();
        let editor = Rc::new(Self {
            ui: Rc::clone(ui),
            subject: subject.clone(),
            dialog: adw::Dialog::builder()
                .title("Artwork")
                .follows_content_size(false)
                .build(),
            crop,
            backdrop: gtk::DrawingArea::builder().hexpand(true).vexpand(true).build(),
            spinner: gtk::Spinner::builder()
                .halign(gtk::Align::Center)
                .valign(gtk::Align::Center)
                .width_request(32)
                .height_request(32)
                .build(),
            empty: gtk::Label::builder()
                .label("Choose an image, paste one,\nor drop it here")
                .justify(gtk::Justification::Center)
                .halign(gtk::Align::Center)
                .valign(gtk::Align::Center)
                .can_target(false)
                .build(),
            info: gtk::Label::builder().xalign(0.5).wrap(true).build(),
            soft: gtk::Box::new(gtk::Orientation::Horizontal, 6),
            zoom: gtk::Scale::with_range(gtk::Orientation::Horizontal, 0.0, 1.0, 0.005),
            zoom_syncing: Cell::new(false),
            save: gtk::Button::with_label("Save"),
            reset: gtk::Button::new(),
            paste: gtk::Button::new(),
            files_section: gtk::Box::new(gtk::Orientation::Vertical, 8),
            files_flow: new_flow(),
            online_flow: new_flow(),
            online_status: gtk::Label::builder().xalign(0.0).wrap(true).visible(false).build(),
            online_spinner: gtk::Spinner::new(),
            search_entry: gtk::Entry::builder().hexpand(true).build(),
            tiles: RefCell::new(HashMap::new()),
            selected_tile: RefCell::new(None),
            source_label: RefCell::new(String::new()),
            replaced: Cell::new(false),
            has_custom: Cell::new(has_custom),
            loaded_once: Cell::new(false),
            load_token: Cell::new(0),
            search_token: Cell::new(0),
            busy_saving: Cell::new(false),
            finished: Cell::new(false),
            clipboard_handler: RefCell::new(None),
        });
        editor.assemble();
        editor.wire();
        editor
    }

    pub fn crop(&self) -> &Rc<CropView> {
        &self.crop
    }

    pub fn is_loaded(&self) -> bool {
        self.loaded_once.get() && self.crop.has_image()
    }

    pub fn is_finished(&self) -> bool {
        self.finished.get()
    }

    pub fn save_is_enabled(&self) -> bool {
        self.save.is_sensitive()
    }

    pub fn reset_is_visible(&self) -> bool {
        self.reset.is_visible()
    }

    pub fn info_text(&self) -> String {
        self.info.label().to_string()
    }

    pub fn soft_is_visible(&self) -> bool {
        self.soft.opacity() > 0.5
    }

    pub fn zoom_value(&self) -> f64 {
        self.zoom.value()
    }

    pub fn files_tile_count(&self) -> usize {
        self.tiles
            .borrow()
            .keys()
            .filter(|id| {
                id.starts_with("file:") || id.starts_with("embedded:") || id.starts_with("album:")
            })
            .count()
    }

    pub fn online_tile_count(&self) -> usize {
        self.tiles
            .borrow()
            .keys()
            .filter(|id| id.starts_with("online:"))
            .count()
    }

    fn present(self: &Rc<Self>, preload: Option<Payload>) {
        let window = &self.ui.window;
        let width = (window.width() - 100).clamp(760, 1040);
        let height = (window.height() - 120).clamp(560, 720);
        self.dialog.set_content_width(width);
        self.dialog.set_content_height(height);
        self.dialog.present(Some(window));
        self.crop.area().grab_focus();
        match preload {
            Some(payload) => {
                self.load(LoadRequest {
                    payload,
                    label: "Dropped image".to_string(),
                    tile: None,
                    failure: "That file couldn't be read as an image.",
                    user_initiated: true,
                });
            }
            None => self.load_current(),
        }
        self.start_local_shelf();
        self.run_search();
        self.refresh_paste();
    }

    fn assemble(self: &Rc<Self>) {
        let header = adw::HeaderBar::new();
        header.set_show_start_title_buttons(false);
        header.set_show_end_title_buttons(false);
        header.set_title_widget(Some(&adw::WindowTitle::new(
            if self.subject.is_playlist() { "Playlist Cover" } else { "Artwork" },
            &self.subject.subtitle(),
        )));

        let columns = gtk::Box::new(gtk::Orientation::Horizontal, 28);
        columns.set_margin_start(24);
        columns.set_margin_end(24);
        columns.set_margin_top(8);
        columns.set_margin_bottom(16);
        columns.append(&self.left_column());
        columns.append(&self.right_column());

        let layers = gtk::Overlay::new();
        layers.set_child(Some(&self.backdrop));
        layers.add_overlay(&columns);
        layers.set_measure_overlay(&columns, true);
        layers.add_css_class("artwork-editor");

        let toolbar = adw::ToolbarView::new();
        toolbar.add_top_bar(&header);
        toolbar.set_content(Some(&layers));
        toolbar.add_bottom_bar(&self.footer());
        self.dialog.set_child(Some(&toolbar));
        self.dialog.set_default_widget(Some(&self.save));
    }

    fn left_column(self: &Rc<Self>) -> gtk::Box {
        let column = gtk::Box::new(gtk::Orientation::Vertical, 12);
        column.set_hexpand(true);
        column.set_width_request(420);

        let frame = gtk::AspectFrame::new(0.5, 0.5, 1.0, false);
        frame.set_vexpand(true);
        frame.set_hexpand(true);
        frame.set_child(Some(self.crop.area()));
        let layers = gtk::Overlay::new();
        layers.set_child(Some(&frame));
        layers.add_overlay(&self.spinner);
        layers.add_overlay(&self.empty);
        layers.set_vexpand(true);
        layers.add_css_class("artwork-crop-host");
        self.empty.add_css_class("dim");
        column.append(&layers);

        column.append(&self.zoom_row());

        self.info.add_css_class("caption");
        self.info.add_css_class("dim");
        column.append(&self.info);

        let warning = gtk::Image::from_icon_name("flaccy-warning-symbolic");
        let text = gtk::Label::new(Some(SOFT_WARNING));
        text.add_css_class("caption");
        self.soft.append(&warning);
        self.soft.append(&text);
        self.soft.set_halign(gtk::Align::Center);
        self.soft.add_css_class("artwork-soft");
        self.soft.set_opacity(0.0);
        column.append(&self.soft);

        column.append(&self.previews_row());
        column
    }

    fn zoom_row(self: &Rc<Self>) -> gtk::Box {
        let row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        let out = gtk::Button::from_icon_name("flaccy-zoom-out-symbolic");
        out.add_css_class("flat");
        out.add_css_class("circular");
        out.set_tooltip_text(Some("Zoom out"));
        out.update_property(&[gtk::accessible::Property::Label("Zoom out")]);
        let into = gtk::Button::from_icon_name("flaccy-zoom-in-symbolic");
        into.add_css_class("flat");
        into.add_css_class("circular");
        into.set_tooltip_text(Some("Zoom in"));
        into.update_property(&[gtk::accessible::Property::Label("Zoom in")]);
        self.zoom.set_hexpand(true);
        self.zoom.set_draw_value(false);
        self.zoom.set_sensitive(false);
        self.zoom
            .update_property(&[gtk::accessible::Property::Label("Zoom")]);
        let fit = gtk::Button::with_label("Fit");
        fit.set_tooltip_text(Some("Fill the frame and centre the cover (0)"));
        fit.update_property(&[gtk::accessible::Property::Label("Fit")]);
        {
            let crop = Rc::clone(&self.crop);
            out.connect_clicked(move |_| crop.zoom_by(1.0 / KEY_ZOOM_FACTOR, None));
        }
        {
            let crop = Rc::clone(&self.crop);
            into.connect_clicked(move |_| crop.zoom_by(KEY_ZOOM_FACTOR, None));
        }
        {
            let crop = Rc::clone(&self.crop);
            fit.connect_clicked(move |_| {
                crop.fit();
                crop.area().grab_focus();
            });
        }
        {
            let crop = Rc::clone(&self.crop);
            let weak = Rc::downgrade(self);
            self.zoom.connect_value_changed(move |scale| {
                if weak.upgrade().is_some_and(|editor| editor.zoom_syncing.get()) {
                    return;
                }
                crop.zoom_to_fraction(scale.value());
            });
        }
        row.append(&out);
        row.append(&self.zoom);
        row.append(&into);
        row.append(&fit);
        row
    }

    fn previews_row(self: &Rc<Self>) -> gtk::Box {
        let section = gtk::Box::new(gtk::Orientation::Horizontal, 22);
        section.set_valign(gtk::Align::End);
        let caption = gtk::Label::builder()
            .label("PREVIEWS")
            .xalign(0.0)
            .valign(gtk::Align::Start)
            .build();
        caption.add_css_class("eq-caption");
        section.append(&caption);
        let row = gtk::Box::new(gtk::Orientation::Horizontal, 20);
        row.set_valign(gtk::Align::End);
        for (side, radius, name) in self.subject.previews() {
            let item = gtk::Box::new(gtk::Orientation::Vertical, 4);
            item.set_valign(gtk::Align::End);
            let area = preview_area(&self.crop, side, radius);
            area.update_property(&[gtk::accessible::Property::Label(&format!(
                "{name} preview"
            ))]);
            item.append(&area);
            let label = gtk::Label::builder().label(name).xalign(0.0).build();
            label.add_css_class("eq-hint");
            item.append(&label);
            row.append(&item);
        }
        section.append(&row);
        section
    }

    fn right_column(self: &Rc<Self>) -> gtk::ScrolledWindow {
        let column = gtk::Box::new(gtk::Orientation::Vertical, 18);
        column.set_margin_end(4);
        column.append(&self.source_actions());

        self.files_section.append(&section_header(self.subject.shelf_title(), None));
        self.files_section.append(&self.files_flow);
        self.files_section.set_visible(false);
        column.append(&self.files_section);

        column.append(&self.online_section());

        let scroll = gtk::ScrolledWindow::builder()
            .hscrollbar_policy(gtk::PolicyType::Never)
            .vexpand(true)
            .width_request(360)
            .child(&column)
            .build();
        scroll.add_css_class("artwork-sources");
        scroll
    }

    fn source_actions(self: &Rc<Self>) -> gtk::Box {
        let section = gtk::Box::new(gtk::Orientation::Vertical, 8);
        let row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        let choose = icon_button("flaccy-folder-open-symbolic", "Choose File…");
        choose.set_tooltip_text(Some("Choose an image file (Ctrl+O)"));
        choose.update_property(&[gtk::accessible::Property::Label("Choose File")]);
        let paste_content = button_content("flaccy-paste-symbolic", "Paste");
        self.paste.set_child(Some(&paste_content));
        self.paste.set_tooltip_text(Some("Paste an image, file or link (Ctrl+V)"));
        self.paste.update_property(&[gtk::accessible::Property::Label("Paste")]);
        self.paste.set_sensitive(false);
        {
            let weak = Rc::downgrade(self);
            choose.connect_clicked(move |_| {
                if let Some(editor) = weak.upgrade() {
                    editor.choose_file();
                }
            });
        }
        {
            let weak = Rc::downgrade(self);
            self.paste.connect_clicked(move |_| {
                if let Some(editor) = weak.upgrade() {
                    editor.paste_from_clipboard();
                }
            });
        }
        row.append(&choose);
        row.append(&self.paste);
        section.append(&row);
        let hint = gtk::Label::builder()
            .label("or drop an image here")
            .xalign(0.0)
            .build();
        hint.add_css_class("eq-hint");
        section.append(&hint);
        section
    }

    fn online_section(self: &Rc<Self>) -> gtk::Box {
        let section = gtk::Box::new(gtk::Orientation::Vertical, 8);
        section.append(&section_header("Find Online", Some(&self.online_spinner)));
        let search_row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        self.search_entry.set_text(&self.subject.default_query());
        self.search_entry
            .set_placeholder_text(Some(self.subject.search_placeholder()));
        self.search_entry
            .update_property(&[gtk::accessible::Property::Label("Search for covers online")]);
        let search = gtk::Button::with_label("Search");
        search.update_property(&[gtk::accessible::Property::Label("Search")]);
        {
            let weak = Rc::downgrade(self);
            self.search_entry.connect_activate(move |_| {
                if let Some(editor) = weak.upgrade() {
                    editor.run_search();
                }
            });
        }
        {
            let weak = Rc::downgrade(self);
            search.connect_clicked(move |_| {
                if let Some(editor) = weak.upgrade() {
                    editor.run_search();
                }
            });
        }
        search_row.append(&self.search_entry);
        search_row.append(&search);
        section.append(&search_row);
        self.online_status.add_css_class("caption");
        self.online_status.add_css_class("dim");
        section.append(&self.online_status);
        section.append(&self.online_flow);
        section
    }

    fn footer(self: &Rc<Self>) -> gtk::Box {
        let bar = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        bar.set_margin_start(24);
        bar.set_margin_end(24);
        bar.set_margin_top(10);
        bar.set_margin_bottom(14);
        let reset_content = button_content("flaccy-undo-symbolic", self.subject.reset_label());
        self.reset.set_child(Some(&reset_content));
        self.reset.add_css_class("flat");
        self.reset.add_css_class("destructive-action");
        self.reset.set_visible(self.has_custom.get());
        self.reset
            .update_property(&[gtk::accessible::Property::Label(self.subject.reset_label())]);
        {
            let weak = Rc::downgrade(self);
            self.reset.connect_clicked(move |_| {
                if let Some(editor) = weak.upgrade() {
                    editor.confirm_reset();
                }
            });
        }
        let spacer = gtk::Box::new(gtk::Orientation::Horizontal, 0);
        spacer.set_hexpand(true);
        let cancel = gtk::Button::with_label("Cancel");
        cancel.update_property(&[gtk::accessible::Property::Label("Cancel")]);
        {
            let weak = Rc::downgrade(self);
            cancel.connect_clicked(move |_| {
                if let Some(editor) = weak.upgrade() {
                    editor.dialog.close();
                }
            });
        }
        self.save.add_css_class("suggested-action");
        self.save.set_sensitive(false);
        self.save.set_tooltip_text(Some("Save (Ctrl+Enter)"));
        self.save
            .update_property(&[gtk::accessible::Property::Label("Save")]);
        {
            let weak = Rc::downgrade(self);
            self.save.connect_clicked(move |_| {
                if let Some(editor) = weak.upgrade() {
                    editor.save();
                }
            });
        }
        bar.append(&self.reset);
        bar.append(&spacer);
        bar.append(&cancel);
        bar.append(&self.save);
        bar
    }

    fn wire(self: &Rc<Self>) {
        self.wire_backdrop();
        self.wire_framing();
        self.wire_closing();
        self.wire_drop();
        self.wire_shortcuts();
        self.wire_clipboard();
    }

    fn wire_backdrop(self: &Rc<Self>) {
        let weak = Rc::downgrade(self);
        self.backdrop.set_draw_func(move |_, cr, width, height| {
            let Some(editor) = weak.upgrade() else { return };
            if let Some(source) = editor.crop.source() {
                source.paint_backdrop(cr, width as f64, height as f64);
            }
            let dark = adw::StyleManager::default().is_dark();
            if dark {
                cr.set_source_rgba(0.0, 0.0, 0.0, 0.66);
            } else {
                cr.set_source_rgba(1.0, 1.0, 1.0, 0.78);
            }
            let _ = cr.paint();
        });
        let weak = self.backdrop.downgrade();
        adw::StyleManager::default().connect_dark_notify(move |_| {
            if let Some(backdrop) = weak.upgrade() {
                backdrop.queue_draw();
            }
        });
    }

    fn wire_framing(self: &Rc<Self>) {
        let weak = Rc::downgrade(self);
        self.crop.connect_changed(move || {
            if let Some(editor) = weak.upgrade() {
                editor.framing_changed();
            }
        });
    }

    /// Everything that depends on how the cover is framed: the zoom slider,
    /// the soft-resolution warning, whether Save has anything to save and
    /// whether closing needs to ask first.
    fn framing_changed(&self) {
        let framing = self.crop.framing();
        self.zoom_syncing.set(true);
        self.zoom.set_value(framing.map_or(0.0, |f| f.zoom_fraction()));
        self.zoom_syncing.set(false);
        self.zoom.set_sensitive(framing.is_some());
        self.soft.set_opacity(if framing.is_some_and(|f| f.is_soft()) { 1.0 } else { 0.0 });
        let unsaved = self.has_unsaved_changes();
        self.save
            .set_sensitive(unsaved && self.crop.has_image() && !self.busy_saving.get());
        self.dialog.set_can_close(!unsaved);
    }

    fn has_unsaved_changes(&self) -> bool {
        self.replaced.get() || !self.crop.is_pristine()
    }

    fn wire_closing(self: &Rc<Self>) {
        let weak = Rc::downgrade(self);
        self.dialog.connect_close_attempt(move |_| {
            if let Some(editor) = weak.upgrade() {
                editor.confirm_discard();
            }
        });
        let weak = Rc::downgrade(self);
        self.dialog.connect_closed(move |_| {
            let Some(editor) = weak.upgrade() else { return };
            editor.finished.set(true);
            editor.load_token.set(editor.load_token.get() + 1);
            editor.search_token.set(editor.search_token.get() + 1);
            if let Some(handler) = editor.clipboard_handler.borrow_mut().take() {
                editor.ui.window.clipboard().disconnect(handler);
            }
            CURRENT.with(|slot| {
                let mut slot = slot.borrow_mut();
                if slot.as_ref().is_some_and(|open| Rc::ptr_eq(open, &editor)) {
                    *slot = None;
                }
            });
        });
    }

    fn confirm_discard(self: &Rc<Self>) {
        let alert = adw::AlertDialog::new(
            Some("Discard changes?"),
            Some("Your changes to this cover haven't been saved."),
        );
        alert.add_responses(&[("keep", "Keep Editing"), ("discard", "Discard Changes")]);
        alert.set_response_appearance("discard", adw::ResponseAppearance::Destructive);
        alert.set_default_response(Some("keep"));
        alert.set_close_response("keep");
        let weak = Rc::downgrade(self);
        alert.connect_response(None, move |_, response| {
            if response == "discard" {
                if let Some(editor) = weak.upgrade() {
                    editor.dialog.force_close();
                }
            }
        });
        alert.present(Some(&self.dialog));
    }

    fn wire_drop(self: &Rc<Self>) {
        let target = gtk::DropTarget::new(glib::Type::INVALID, gdk::DragAction::COPY);
        target.set_types(&[
            gdk::FileList::static_type(),
            gdk::Texture::static_type(),
            String::static_type(),
        ]);
        let weak = Rc::downgrade(self);
        target.connect_drop(move |_, value, _, _| {
            let Some(editor) = weak.upgrade() else {
                return false;
            };
            let Some(payload) = payload_from_value(value) else {
                editor.info.set_label("That isn't an image Flaccy can use.");
                return false;
            };
            editor.load(LoadRequest {
                payload,
                label: "Dropped image".to_string(),
                tile: None,
                failure: "That file couldn't be read as an image.",
                user_initiated: true,
            });
            true
        });
        let weak = Rc::downgrade(self);
        target.connect_enter(move |_, _, _| {
            if let Some(editor) = weak.upgrade() {
                editor.crop.area().add_css_class("artwork-drop-active");
            }
            gdk::DragAction::COPY
        });
        let weak = Rc::downgrade(self);
        target.connect_leave(move |_| {
            if let Some(editor) = weak.upgrade() {
                editor.crop.area().remove_css_class("artwork-drop-active");
            }
        });
        if let Some(child) = self.dialog.child() {
            child.add_controller(target);
        }
    }

    fn wire_shortcuts(self: &Rc<Self>) {
        let keys = gtk::EventControllerKey::new();
        keys.set_propagation_phase(gtk::PropagationPhase::Capture);
        let weak = Rc::downgrade(self);
        keys.connect_key_pressed(move |_, key, _, state| {
            let Some(editor) = weak.upgrade() else {
                return glib::Propagation::Proceed;
            };
            if !state.contains(gdk::ModifierType::CONTROL_MASK) {
                return glib::Propagation::Proceed;
            }
            let typing = editor
                .dialog
                .focus()
                .is_some_and(|widget| widget.is::<gtk::Text>() || widget.is::<gtk::Entry>());
            match key {
                gdk::Key::o | gdk::Key::O => editor.choose_file(),
                gdk::Key::v | gdk::Key::V if !typing => editor.paste_from_clipboard(),
                gdk::Key::Return | gdk::Key::KP_Enter => editor.save(),
                _ => return glib::Propagation::Proceed,
            }
            glib::Propagation::Stop
        });
        if let Some(child) = self.dialog.child() {
            child.add_controller(keys);
        }
    }

    fn wire_clipboard(self: &Rc<Self>) {
        let weak = Rc::downgrade(self);
        let handler = self.ui.window.clipboard().connect_changed(move |_| {
            if let Some(editor) = weak.upgrade() {
                editor.refresh_paste();
            }
        });
        *self.clipboard_handler.borrow_mut() = Some(handler);
    }

    /// Paste is live when the clipboard holds an image, a file, or text that
    /// names one; otherwise it is dimmed.
    fn refresh_paste(self: &Rc<Self>) {
        let clipboard = self.ui.window.clipboard();
        let formats = clipboard.formats();
        if formats.contains_type(gdk::Texture::static_type())
            || formats.contains_type(gdk::FileList::static_type())
        {
            self.paste.set_sensitive(true);
            return;
        }
        self.paste.set_sensitive(false);
        if !formats.contains_type(String::static_type()) {
            return;
        }
        let weak = Rc::downgrade(self);
        clipboard.read_text_async(None::<&gio::Cancellable>, move |result| {
            let usable = result
                .ok()
                .flatten()
                .is_some_and(|text| payload_from_text(&text).is_some());
            if let Some(editor) = weak.upgrade() {
                editor.paste.set_sensitive(usable);
            }
        });
    }

    fn paste_from_clipboard(self: &Rc<Self>) {
        if !self.paste.is_sensitive() {
            return;
        }
        let clipboard = self.ui.window.clipboard();
        let formats = clipboard.formats();
        let weak = Rc::downgrade(self);
        if formats.contains_type(gdk::Texture::static_type()) {
            clipboard.read_texture_async(None::<&gio::Cancellable>, move |result| {
                let payload = result
                    .ok()
                    .flatten()
                    .map(|texture| Payload::Bytes(texture.save_to_png_bytes().to_vec()));
                if let Some(editor) = weak.upgrade() {
                    editor.finish_paste(payload);
                }
            });
        } else if formats.contains_type(gdk::FileList::static_type()) {
            clipboard.read_value_async(
                gdk::FileList::static_type(),
                glib::Priority::DEFAULT,
                None::<&gio::Cancellable>,
                move |result| {
                    let payload = result.ok().and_then(|value| payload_from_value(&value));
                    if let Some(editor) = weak.upgrade() {
                        editor.finish_paste(payload);
                    }
                },
            );
        } else {
            clipboard.read_text_async(None::<&gio::Cancellable>, move |result| {
                let payload = result
                    .ok()
                    .flatten()
                    .and_then(|text| payload_from_text(&text));
                if let Some(editor) = weak.upgrade() {
                    editor.finish_paste(payload);
                }
            });
        }
    }

    fn finish_paste(self: &Rc<Self>, payload: Option<Payload>) {
        match payload {
            Some(payload) => self.load(LoadRequest {
                payload,
                label: "Clipboard".to_string(),
                tile: None,
                failure: "That couldn't be read as an image.",
                user_initiated: true,
            }),
            None => self.info.set_label("Nothing on the clipboard can be used as a cover."),
        }
    }

    fn choose_file(self: &Rc<Self>) {
        let filter = gtk::FileFilter::new();
        filter.set_name(Some("Images"));
        for mime in ["image/jpeg", "image/png", "image/webp"] {
            filter.add_mime_type(mime);
        }
        for suffix in ["jpg", "jpeg", "png", "webp"] {
            filter.add_suffix(suffix);
        }
        let filters = gio::ListStore::new::<gtk::FileFilter>();
        filters.append(&filter);
        let chooser = gtk::FileDialog::builder()
            .title("Choose Artwork")
            .modal(true)
            .filters(&filters)
            .default_filter(&filter)
            .build();
        let weak = Rc::downgrade(self);
        chooser.open(
            Some(&self.ui.window),
            None::<&gio::Cancellable>,
            move |result| {
                let Ok(file) = result else { return };
                let Some(editor) = weak.upgrade() else { return };
                let Some(path) = file.path() else {
                    editor.info.set_label("That file couldn't be opened.");
                    return;
                };
                let label = path
                    .file_stem()
                    .map(|stem| stem.to_string_lossy().to_string())
                    .unwrap_or_else(|| "Image".to_string());
                editor.load(LoadRequest {
                    payload: Payload::Path(path),
                    label,
                    tile: None,
                    failure: "That file couldn't be read as an image.",
                    user_initiated: true,
                });
            },
        );
    }

    fn load_current(self: &Rc<Self>) {
        let (subject, path) = (self.subject.clone(), self.ui.core.db_path.clone());
        let token = self.bump_load_token();
        let weak = Rc::downgrade(self);
        spawn_work(
            "flaccy-artwork-current",
            move || {
                let db = Db::open(&path).ok()?;
                let bytes = subject.current_cover(&db)?;
                decode_payload(Payload::Bytes(bytes)).ok()
            },
            move |loaded| {
                let Some(editor) = weak.upgrade() else { return };
                if token != editor.load_token.get() {
                    return;
                }
                match loaded {
                    Some(loaded) => editor.adopt(loaded, "Current artwork", false, None),
                    None => editor.show_empty(),
                }
            },
        );
    }

    fn bump_load_token(&self) -> u64 {
        let token = self.load_token.get() + 1;
        self.load_token.set(token);
        token
    }

    fn show_empty(&self) {
        self.empty.set_visible(!self.crop.has_image());
    }

    /// Reads and decodes a picture off the main thread. A newer request
    /// supersedes this one, and a failure leaves the previous image where it
    /// was.
    fn load(self: &Rc<Self>, request: LoadRequest) {
        let token = self.bump_load_token();
        self.crop.set_loading(true);
        self.spinner.start();
        self.info.set_label(&format!("Loading {}…", request.label));
        let LoadRequest {
            payload,
            label,
            tile,
            failure,
            user_initiated,
        } = request;
        let weak = Rc::downgrade(self);
        spawn_work(
            "flaccy-artwork-load",
            move || decode_payload(payload),
            move |result| {
                let Some(editor) = weak.upgrade() else { return };
                if token != editor.load_token.get() {
                    return;
                }
                editor.crop.set_loading(false);
                editor.spinner.stop();
                match result {
                    Ok(loaded) => editor.adopt(loaded, &label, user_initiated, tile),
                    Err(LoadFailure::Unreadable) => editor.fail(failure),
                    Err(LoadFailure::Message(message)) => {
                        crate::logger::warn("artwork", &format!("load failed: {message}"));
                        editor.fail(failure);
                    }
                }
            },
        );
    }

    fn fail(&self, message: &str) {
        self.select_tile(None);
        self.info.set_label(message);
        self.restore_info_after_failure();
    }

    fn restore_info_after_failure(&self) {
        self.show_empty();
    }

    fn adopt(&self, loaded: Loaded, label: &str, user_initiated: bool, tile: Option<String>) {
        let source = ArtworkSource::new(loaded.chain);
        self.info
            .set_label(&format!("{label} · {} × {}", source.width, source.height));
        *self.source_label.borrow_mut() = label.to_string();
        if user_initiated {
            self.replaced.set(true);
        }
        self.loaded_once.set(true);
        self.empty.set_visible(false);
        self.crop.set_source(Some(source));
        self.select_tile(tile);
        self.backdrop.queue_draw();
        if user_initiated {
            self.crop.area().grab_focus();
        }
        self.framing_changed();
    }

    fn select_tile(&self, id: Option<String>) {
        let previous = self.selected_tile.replace(id.clone());
        let tiles = self.tiles.borrow();
        if let Some(tile) = previous.and_then(|old| tiles.get(&old)) {
            tile.button.remove_css_class("artwork-tile-selected");
        }
        if let Some(tile) = id.and_then(|new| tiles.get(&new)) {
            tile.button.add_css_class("artwork-tile-selected");
        }
    }

    fn start_local_shelf(self: &Rc<Self>) {
        let Subject::Album(album) = &self.subject else {
            self.start_playlist_shelf();
            return;
        };
        let root = self.ui.core.music_root();
        let tracks: Vec<(String, i32)> = album
            .tracks
            .iter()
            .map(|track| (track.rel_path.clone(), track.track_number))
            .collect();
        let relative: Vec<String> = tracks.iter().map(|(path, _)| path.clone()).collect();
        let weak = Rc::downgrade(self);
        spawn_stream(
            "flaccy-artwork-local",
            move |tx| {
                let covers = local_artwork::folder_images(&root, &relative)
                    .into_iter()
                    .chain(local_artwork::embedded_images(&root, &tracks));
                for cover in covers {
                    let thumbnail = cover
                        .bytes()
                        .and_then(|bytes| artwork_image::thumbnail(&bytes, LOCAL_THUMBNAIL));
                    if tx.send_blocking((cover, thumbnail)).is_err() {
                        break;
                    }
                }
            },
            move |(cover, thumbnail)| {
                if let Some(editor) = weak.upgrade() {
                    editor.add_local_tile(cover, thumbnail);
                }
            },
        );
    }

    /// The covers of the albums the playlist draws from, one tile each in
    /// playlist order and captioned with the album's title. They come from the
    /// database's hoisted covers, so nothing is read off the disk.
    fn start_playlist_shelf(self: &Rc<Self>) {
        let Subject::Playlist { tracks, .. } = &self.subject else {
            return;
        };
        let albums = playlist_cover::shelf_albums(
            &tracks
                .iter()
                .map(|track| (track.album.clone(), track.artist.clone()))
                .collect::<Vec<_>>(),
        );
        let path = self.ui.core.db_path.clone();
        let weak = Rc::downgrade(self);
        spawn_stream(
            "flaccy-artwork-playlist-shelf",
            move |tx| {
                let Ok(db) = Db::open(&path) else { return };
                let mut seen = std::collections::HashSet::new();
                for (title, artist) in albums {
                    let Some(bytes) = db.fetch_album_artwork(&title, &artist) else {
                        continue;
                    };
                    if !seen.insert(local_artwork::content_hash(&bytes)) {
                        continue;
                    }
                    let Some((width, height)) = artwork_image::dimensions(&bytes) else {
                        continue;
                    };
                    let thumbnail = artwork_image::thumbnail(&bytes, LOCAL_THUMBNAIL);
                    let cover = LocalCover {
                        caption: title.clone(),
                        origin: Origin::Embedded(bytes),
                        width,
                        height,
                    };
                    if tx.send_blocking((cover, thumbnail, format!("album:{title}|{artist}"))).is_err() {
                        break;
                    }
                }
            },
            move |(cover, thumbnail, id)| {
                if let Some(editor) = weak.upgrade() {
                    editor.add_local_tile_with_id(cover, thumbnail, id);
                }
            },
        );
    }

    fn add_local_tile(self: &Rc<Self>, cover: LocalCover, thumbnail: Option<RgbaImage>) {
        let id = match &cover.origin {
            Origin::File(path) => format!("file:{}", path.display()),
            Origin::Embedded(_) => format!("embedded:{}", cover.caption),
        };
        self.add_local_tile_with_id(cover, thumbnail, id);
    }

    fn add_local_tile_with_id(self: &Rc<Self>, cover: LocalCover, thumbnail: Option<RgbaImage>, id: String) {
        let payload = match &cover.origin {
            Origin::File(path) => Payload::Path(path.clone()),
            Origin::Embedded(bytes) => Payload::Bytes(bytes.clone()),
        };
        let dimensions = format!("{}×{}", cover.width, cover.height);
        let Tile { button, art } = tile(&cover.caption, Some(&dimensions), &cover.caption);
        if let Some(thumbnail) = thumbnail {
            art.set_image(thumbnail);
        }
        let label = cover.caption.clone();
        let tile_id = id.clone();
        let weak = Rc::downgrade(self);
        button.connect_clicked(move |_| {
            if let Some(editor) = weak.upgrade() {
                editor.load(LoadRequest {
                    payload: payload.clone(),
                    label: label.clone(),
                    tile: Some(tile_id.clone()),
                    failure: "That file couldn't be read as an image.",
                    user_initiated: true,
                });
            }
        });
        self.tiles.borrow_mut().insert(id, Tile { button: button.clone(), art });
        self.files_flow.append(&button);
        self.files_section.set_visible(true);
    }

    fn run_search(self: &Rc<Self>) {
        let token = self.search_token.get() + 1;
        self.search_token.set(token);
        let query = self.search_entry.text().to_string();
        if self.subject.is_playlist() && query.trim().is_empty() {
            self.clear_online();
            self.online_spinner.stop();
            self.online_status
                .set_label("Search Apple Music, Deezer and the Cover Art Archive.");
            self.online_status.set_visible(true);
            return;
        }
        let request = Request::new(&query, self.subject.title(), self.subject.credit());
        self.clear_online();
        self.online_spinner.start();
        self.online_status.set_visible(false);
        let weak = Rc::downgrade(self);
        spawn_work(
            "flaccy-artwork-search",
            move || artwork_search::search(&request),
            move |outcome| {
                let Some(editor) = weak.upgrade() else { return };
                if token != editor.search_token.get() {
                    return;
                }
                editor.show_results(token, outcome);
            },
        );
    }

    fn clear_online(&self) {
        while let Some(child) = self.online_flow.first_child() {
            self.online_flow.remove(&child);
        }
        let mut tiles = self.tiles.borrow_mut();
        tiles.retain(|id, _| !id.starts_with("online:"));
    }

    fn show_results(self: &Rc<Self>, token: u64, outcome: artwork_search::SearchOutcome) {
        if outcome.candidates.is_empty() {
            self.online_spinner.stop();
            let message = if outcome.unreachable() {
                "Couldn't reach the online catalogs. Check your connection."
            } else {
                "No matching covers found online."
            };
            self.online_status.set_label(message);
            self.online_status.set_visible(true);
            return;
        }
        let pending = Rc::new(Cell::new(outcome.candidates.len()));
        let mut slots: HashMap<String, Tile> = HashMap::new();
        for candidate in &outcome.candidates {
            let id = format!("online:{}", candidate.id);
            let made = tile(
                candidate.source,
                None,
                &format!(
                    "{} by {}, {}",
                    candidate.title, candidate.artist, candidate.source
                ),
            );
            made.button.set_sensitive(false);
            self.tiles.borrow_mut().insert(id.clone(), made.clone());
            self.online_flow.append(&made.button);
            slots.insert(id, made);
        }
        let candidates = outcome.candidates;
        let (queue_tx, queue_rx) = async_channel::unbounded::<Candidate>();
        for candidate in &candidates {
            let _ = queue_tx.send_blocking(candidate.clone());
        }
        queue_tx.close();
        let (result_tx, result_rx) = async_channel::unbounded::<(Candidate, Option<RgbaImage>)>();
        for _ in 0..THUMBNAIL_WORKERS {
            let queue_rx = queue_rx.clone();
            let result_tx = result_tx.clone();
            std::thread::Builder::new()
                .name("flaccy-artwork-thumb".into())
                .spawn(move || {
                    while let Ok(candidate) = queue_rx.recv_blocking() {
                        let image = artwork_search::fetch_bytes(
                            &candidate.thumbnail_url,
                            false,
                            ONLINE_THUMBNAIL_BYTES,
                        )
                        .ok()
                        .and_then(|bytes| artwork_image::thumbnail(&bytes, 360));
                        if result_tx.send_blocking((candidate, image)).is_err() {
                            break;
                        }
                    }
                })
                .ok();
        }
        drop(result_tx);
        let weak = Rc::downgrade(self);
        glib::spawn_future_local(async move {
            while let Ok((candidate, image)) = result_rx.recv().await {
                let Some(editor) = weak.upgrade() else { return };
                if token != editor.search_token.get() {
                    return;
                }
                let id = format!("online:{}", candidate.id);
                editor.settle_online_tile(&slots, &id, candidate, image);
                pending.set(pending.get() - 1);
                if pending.get() == 0 {
                    editor.finish_search();
                }
            }
        });
    }

    fn settle_online_tile(
        self: &Rc<Self>,
        slots: &HashMap<String, Tile>,
        id: &str,
        candidate: Candidate,
        image: Option<RgbaImage>,
    ) {
        let Some(Tile { button, art }) = slots.get(id) else {
            return;
        };
        let Some(image) = image else {
            if let Some(parent) = button.parent() {
                self.online_flow.remove(&parent);
            }
            self.tiles.borrow_mut().remove(id);
            return;
        };
        art.set_image(image);
        button.set_sensitive(true);
        let weak = Rc::downgrade(self);
        let tile_id = id.to_string();
        button.connect_clicked(move |_| {
            if let Some(editor) = weak.upgrade() {
                editor.load(LoadRequest {
                    payload: Payload::Url(candidate.full_url.clone()),
                    label: candidate.source.to_string(),
                    tile: Some(tile_id.clone()),
                    failure: "Couldn't download that cover. Check your connection and try another.",
                    user_initiated: true,
                });
            }
        });
    }

    fn finish_search(&self) {
        self.online_spinner.stop();
        if self.online_tile_count() == 0 {
            self.online_status.set_label("No matching covers found online.");
            self.online_status.set_visible(true);
        }
    }

    pub fn save(self: &Rc<Self>) {
        if !self.save.is_sensitive() || self.busy_saving.get() {
            return;
        }
        let (Some(source), Some(framing)) = (self.crop.source(), self.crop.framing()) else {
            return;
        };
        self.busy_saving.set(true);
        self.save.set_sensitive(false);
        self.spinner.start();
        let chain = source.chain();
        let subject = self.subject.clone();
        let path = self.ui.core.db_path.clone();
        let weak = Rc::downgrade(self);
        spawn_work(
            "flaccy-artwork-save",
            move || -> Result<usize, String> {
                let jpeg = artwork_image::render_jpeg(chain.full(), &framing)
                    .ok_or_else(|| "the cover could not be rendered".to_string())?;
                let db = Db::open(&path).map_err(|err| err.to_string())?;
                subject.save_cover(&db, &jpeg).map_err(|err| err.to_string())?;
                Ok(jpeg.len())
            },
            move |result| {
                let Some(editor) = weak.upgrade() else { return };
                editor.busy_saving.set(false);
                editor.spinner.stop();
                match result {
                    Ok(bytes) => {
                        crate::logger::info(
                            "artwork",
                            &format!(
                                "custom cover saved for {} ({} KB)",
                                editor.subject.title(),
                                bytes / 1024
                            ),
                        );
                        editor.subject.announce_change(&editor.ui.core);
                        editor.ui.core.toast("Artwork updated");
                        editor.dialog.force_close();
                    }
                    Err(message) => {
                        crate::logger::error("artwork", &format!("saving cover failed: {message}"));
                        editor.info.set_label("Couldn't save the artwork. Try again.");
                        editor.framing_changed();
                    }
                }
            },
        );
    }

    fn confirm_reset(self: &Rc<Self>) {
        let alert = adw::AlertDialog::new(
            Some(self.subject.reset_heading()),
            Some(self.subject.reset_body()),
        );
        alert.add_responses(&[
            ("cancel", "Cancel"),
            (
                "original",
                if self.subject.is_playlist() { "Use Automatic" } else { "Use Original" },
            ),
        ]);
        alert.set_response_appearance("original", adw::ResponseAppearance::Destructive);
        alert.set_default_response(Some("cancel"));
        alert.set_close_response("cancel");
        let weak = Rc::downgrade(self);
        alert.connect_response(None, move |_, response| {
            if response == "original" {
                if let Some(editor) = weak.upgrade() {
                    editor.reset_now();
                }
            }
        });
        alert.present(Some(&self.dialog));
    }

    pub fn reset_now(self: &Rc<Self>) {
        let subject = self.subject.clone();
        let path = self.ui.core.db_path.clone();
        let weak = Rc::downgrade(self);
        spawn_work(
            "flaccy-artwork-reset",
            move || -> Result<(), String> {
                let db = Db::open(&path).map_err(|err| err.to_string())?;
                subject.clear_cover(&db).map_err(|err| err.to_string())
            },
            move |result| {
                let Some(editor) = weak.upgrade() else { return };
                match result {
                    Ok(()) => {
                        crate::logger::info(
                            "artwork",
                            &format!("custom cover cleared for {}", editor.subject.title()),
                        );
                        editor.subject.announce_change(&editor.ui.core);
                        editor.ui.core.toast(editor.subject.reset_toast());
                        editor.dialog.force_close();
                    }
                    Err(message) => {
                        crate::logger::error("artwork", &format!("resetting cover failed: {message}"));
                        editor.info.set_label("Couldn't restore the original artwork. Try again.");
                    }
                }
            },
        );
    }

    pub fn load_payload(self: &Rc<Self>, payload: Payload, label: &str) {
        self.load(LoadRequest {
            payload,
            label: label.to_string(),
            tile: None,
            failure: "That file couldn't be read as an image.",
            user_initiated: true,
        });
    }

    pub fn search_for(self: &Rc<Self>, query: &str) {
        self.search_entry.set_text(query);
        self.run_search();
    }

    pub fn set_zoom_value(&self, fraction: f64) {
        self.zoom.set_value(fraction);
    }

    pub fn would_ask_before_closing(&self) -> bool {
        !self.dialog.can_close()
    }

    pub fn has_replaced_image(&self) -> bool {
        self.replaced.get()
    }

    pub fn selected_tile_id(&self) -> Option<String> {
        self.selected_tile.borrow().clone()
    }

    pub fn click_first_online_tile(&self) -> bool {
        let button = self
            .tiles
            .borrow()
            .iter()
            .filter(|(id, tile)| id.starts_with("online:") && tile.button.is_sensitive())
            .map(|(_, tile)| tile.button.clone())
            .next();
        button.map(|button| button.emit_clicked()).is_some()
    }

    pub fn click_first_files_tile(&self) -> bool {
        let button = self
            .tiles
            .borrow()
            .iter()
            .filter(|(id, tile)| {
                (id.starts_with("album:") || id.starts_with("file:") || id.starts_with("embedded:"))
                    && tile.button.is_sensitive()
            })
            .map(|(_, tile)| tile.button.clone())
            .next();
        button.map(|button| button.emit_clicked()).is_some()
    }

    pub fn search_text(&self) -> String {
        self.search_entry.text().to_string()
    }

    pub fn online_status_text(&self) -> Option<String> {
        self.online_status
            .is_visible()
            .then(|| self.online_status.label().to_string())
    }

    pub fn close_with_discard(&self) {
        self.dialog.force_close();
    }
}

fn new_flow() -> gtk::FlowBox {
    let flow = gtk::FlowBox::builder()
        .selection_mode(gtk::SelectionMode::None)
        .homogeneous(true)
        .min_children_per_line(2)
        .max_children_per_line(4)
        .column_spacing(10)
        .row_spacing(12)
        .valign(gtk::Align::Start)
        .activate_on_single_click(false)
        .build();
    flow.add_css_class("artwork-shelf");
    flow
}

fn section_header(title: &str, spinner: Option<&gtk::Spinner>) -> gtk::Box {
    let row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    let label = gtk::Label::builder().label(title).xalign(0.0).build();
    label.add_css_class("heading");
    row.append(&label);
    if let Some(spinner) = spinner {
        row.append(spinner);
    }
    row
}

fn button_content(icon: &str, text: &str) -> gtk::Box {
    let content = gtk::Box::new(gtk::Orientation::Horizontal, 6);
    content.set_halign(gtk::Align::Center);
    content.append(&gtk::Image::from_icon_name(icon));
    content.append(&gtk::Label::new(Some(text)));
    content
}

fn icon_button(icon: &str, text: &str) -> gtk::Button {
    let button = gtk::Button::new();
    button.set_child(Some(&button_content(icon, text)));
    button
}

/// One cover on a shelf: a square picture with its caption (and, for files,
/// its pixel size) beneath, as a flat button.
fn tile(caption: &str, dimensions: Option<&str>, accessible: &str) -> Tile {
    let art = ThumbArea::new(TILE_SIDE, 9.0);
    let column = gtk::Box::new(gtk::Orientation::Vertical, 4);
    column.append(art.area());
    let caption_label = gtk::Label::builder()
        .label(caption)
        .xalign(0.0)
        .ellipsize(gtk::pango::EllipsizeMode::End)
        .max_width_chars(16)
        .build();
    caption_label.add_css_class("caption");
    column.append(&caption_label);
    if let Some(dimensions) = dimensions {
        let label = gtk::Label::builder().label(dimensions).xalign(0.0).build();
        label.add_css_class("caption");
        label.add_css_class("dim");
        column.append(&label);
    }
    let button = gtk::Button::builder().child(&column).build();
    button.add_css_class("flat");
    button.add_css_class("artwork-tile");
    button.set_tooltip_text(Some(accessible));
    button.update_property(&[gtk::accessible::Property::Label(accessible)]);
    Tile { button, art }
}

/// Makes `widget` accept an image dropped on it — a file, image data or a
/// link — and open the editor for the album `album_for` names, with that
/// picture already loaded and framed. Nothing is saved until Save.
pub fn attach_image_drop(
    widget: &impl IsA<gtk::Widget>,
    ui: &Rc<Ui>,
    album_for: impl Fn() -> Option<Album> + 'static,
) {
    attach_subject_drop(widget, ui, move || album_for().map(Subject::Album));
}

/// The same drop target for a playlist's cover: whatever is dropped opens the
/// editor for that playlist with the picture already framed. `playlist_for`
/// names the playlist at the moment of the drop, so a widget reused for
/// another playlist stays correct.
pub fn attach_playlist_image_drop(
    widget: &impl IsA<gtk::Widget>,
    ui: &Rc<Ui>,
    playlist_for: impl Fn() -> Option<i64> + 'static,
) {
    let resolver = Rc::clone(ui);
    attach_subject_drop(widget, ui, move || {
        playlist_for().map(|playlist_id| playlist_subject(&resolver, playlist_id))
    });
}

fn attach_subject_drop(
    widget: &impl IsA<gtk::Widget>,
    ui: &Rc<Ui>,
    subject_for: impl Fn() -> Option<Subject> + 'static,
) {
    let target = gtk::DropTarget::new(glib::Type::INVALID, gdk::DragAction::COPY);
    target.set_types(&[
        gdk::FileList::static_type(),
        gdk::Texture::static_type(),
        String::static_type(),
    ]);
    let ui = Rc::clone(ui);
    target.connect_drop(move |_, value, _, _| {
        let (Some(subject), Some(payload)) = (subject_for(), payload_from_value(value)) else {
            return false;
        };
        present_subject(&ui, subject, Some(payload));
        true
    });
    let hovered = widget.clone().upcast::<gtk::Widget>();
    target.connect_enter({
        let hovered = hovered.clone();
        move |_, _, _| {
            hovered.add_css_class("artwork-drop-target");
            gdk::DragAction::COPY
        }
    });
    target.connect_leave(move |_| hovered.remove_css_class("artwork-drop-target"));
    widget.add_controller(target);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn playlist(id: i64, name: &str) -> Subject {
        Subject::Playlist {
            id,
            name: name.to_string(),
            tracks: Vec::new(),
        }
    }

    #[test]
    fn a_playlist_is_stored_under_the_one_reserved_key() {
        let subject = playlist(7, "Road Trip");
        assert_eq!(
            subject.artwork_keys(),
            vec![("playlist:7".to_string(), playlist_cover::ARTIST.to_string())]
        );
        assert_eq!(subject.key(), "playlist:7");
        assert_ne!(subject.key(), playlist(8, "Road Trip").key());
    }

    #[test]
    fn a_playlist_search_waits_for_the_person_and_says_what_it_holds() {
        let subject = playlist(1, "Road Trip");
        assert_eq!(subject.default_query(), "");
        assert_eq!(subject.subtitle(), "Road Trip · 0 tracks");
        assert_eq!(track_count_label(1), "1 track");
        assert_eq!(track_count_label(2), "2 tracks");
        assert_eq!(subject.reset_label(), "Use Automatic Cover");
        assert_eq!(subject.previews().len(), 2);
    }

    #[test]
    fn a_link_is_a_link_and_only_the_first_line_counts() {
        match payload_from_text("  https://example.com/cover.jpg \nhttps://other/x.png") {
            Some(Payload::Url(url)) => assert_eq!(url, "https://example.com/cover.jpg"),
            other => panic!("expected a url, got {other:?}"),
        }
        assert!(matches!(
            payload_from_text("# a comment\nhttp://example.com/a.png"),
            Some(Payload::Url(_))
        ));
    }

    #[test]
    fn a_file_uri_and_an_existing_path_become_paths() {
        let dir = std::env::temp_dir().join(format!("flaccy-payload-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("dir");
        let file = dir.join("cover one.png");
        std::fs::write(&file, b"x").expect("file");
        let uri = format!("file://{}/cover%20one.png\r\n", dir.display());
        match payload_from_text(&uri) {
            Some(Payload::Path(path)) => assert_eq!(path, file),
            other => panic!("expected a path from the uri, got {other:?}"),
        }
        match payload_from_text(&file.display().to_string()) {
            Some(Payload::Path(path)) => assert_eq!(path, file),
            other => panic!("expected a path, got {other:?}"),
        }
        assert!(payload_from_text("/definitely/not/here.png").is_none());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn text_that_names_nothing_is_not_a_payload() {
        assert!(payload_from_text("").is_none());
        assert!(payload_from_text("just some words").is_none());
        assert!(payload_from_text("ftp://example.com/a.png").is_none());
        assert!(payload_from_text("relative/path.png").is_none());
    }

    #[test]
    fn a_path_over_the_size_limit_is_refused_before_it_is_read() {
        let path = std::env::temp_dir().join(format!("flaccy-big-{}.png", std::process::id()));
        let file = std::fs::File::create(&path).expect("create");
        file.set_len(artwork_local::MAXIMUM_FILE_BYTES + 1).expect("sparse");
        let outcome = Payload::Path(path.clone()).bytes();
        let _ = std::fs::remove_file(&path);
        assert!(outcome.is_err_and(|message| message.contains("25 MB")));
    }

    #[test]
    fn an_unreadable_payload_fails_to_decode() {
        assert!(matches!(
            decode_payload(Payload::Bytes(b"nope".to_vec())),
            Err(LoadFailure::Unreadable)
        ));
    }
}
