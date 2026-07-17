use crate::db::{NewReleaseRow, WantlistItemRow};
use crate::events::AppEvent;
use crate::ui::Ui;
use adw::prelude::*;
use gtk::glib;
use gtk::pango;
use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::rc::Rc;

#[derive(Clone, Copy, PartialEq, Eq)]
enum Filter {
    All,
    Albums,
    Songs,
    Discover,
    New,
    Upgrades,
}

const FILTERS: [(Filter, &str); 6] = [
    (Filter::All, "All"),
    (Filter::Albums, "Albums"),
    (Filter::Songs, "Songs"),
    (Filter::Discover, "Discover"),
    (Filter::New, "New"),
    (Filter::Upgrades, "Upgrades"),
];

struct Section {
    title: &'static str,
    filters: &'static [Filter],
}

fn section_for(item: &WantlistItemRow) -> Section {
    match (item.kind.as_str(), item.source.as_str()) {
        ("album", "gap") => Section {
            title: "Complete These Albums",
            filters: &[Filter::All, Filter::Albums],
        },
        ("album", "upgrade") => Section {
            title: "Upgrade to Lossless",
            filters: &[Filter::All, Filter::Upgrades],
        },
        ("album", "discovery") => Section {
            title: "Albums to Explore",
            filters: &[Filter::All, Filter::Discover],
        },
        ("album", _) => Section {
            title: "Albums to Get",
            filters: &[Filter::All, Filter::Albums],
        },
        ("track", _) => Section {
            title: "Songs to Get",
            filters: &[Filter::All, Filter::Songs],
        },
        _ => Section {
            title: "Artists to Explore",
            filters: &[Filter::All, Filter::Discover],
        },
    }
}

pub fn build(ui: &Rc<Ui>) -> gtk::Widget {
    let filter = Rc::new(Cell::new(Filter::All));
    let images = Rc::new(RemoteImages::new());

    let content = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(20)
        .margin_top(20)
        .margin_bottom(28)
        .margin_start(28)
        .margin_end(28)
        .build();

    let empty = adw::StatusPage::builder()
        .icon_name("starred-symbolic")
        .title("Nothing on the Wantlist")
        .description("Suggestions build up from your library gaps, lossy albums, and — when Last.fm is connected — your charts and loved tracks.")
        .build();

    let scroll = gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::Never)
        .child(&adw::Clamp::builder().maximum_size(880).child(&content).build())
        .build();
    ui.register_scroller(&scroll);

    let stack = gtk::Stack::new();
    stack.set_hhomogeneous(false);
    stack.set_vhomogeneous(false);
    stack.add_named(&empty, Some("empty"));
    stack.add_named(&scroll, Some("list"));

    let rebuild: Rc<RefCell<Option<Rc<dyn Fn()>>>> = Rc::new(RefCell::new(None));
    let render: Rc<dyn Fn()> = {
        let ui = Rc::clone(ui);
        let filter = Rc::clone(&filter);
        let content = content.clone();
        let stack = stack.clone();
        let images = Rc::clone(&images);
        Rc::new(move || {
            while let Some(child) = content.first_child() {
                content.remove(&child);
            }
            let wanted = ui.core.db.fetch_wanted_items();
            let now = chrono::Utc::now().timestamp();
            let releases: Vec<NewReleaseRow> = ui
                .core
                .db
                .fetch_new_releases()
                .into_iter()
                .filter(|r| r.release_unix > now - 120 * 24 * 3600)
                .collect();
            if wanted.is_empty() && releases.is_empty() {
                stack.set_visible_child_name("empty");
                return;
            }
            stack.set_visible_child_name("list");
            content.append(&toolbar_row(&ui, &filter));

            let active = filter.get();
            if (active == Filter::All || active == Filter::New) && !releases.is_empty() {
                content.append(&section_title("New Releases"));
                let list = section_list();
                for release in &releases {
                    list.append(&release_row(&ui, &images, release));
                }
                content.append(&list);
            }

            let mut grouped: Vec<(&'static str, Vec<&WantlistItemRow>)> = Vec::new();
            for item in &wanted {
                let section = section_for(item);
                if !section.filters.contains(&active) {
                    continue;
                }
                match grouped.iter_mut().find(|(title, _)| *title == section.title) {
                    Some((_, items)) => items.push(item),
                    None => grouped.push((section.title, vec![item])),
                }
            }
            for (title, items) in grouped {
                content.append(&section_title(title));
                let list = section_list();
                for item in items {
                    list.append(&wantlist_row(&ui, &images, item));
                }
                content.append(&list);
            }
        })
    };
    *rebuild.borrow_mut() = Some(Rc::clone(&render));
    render();

    {
        let render = Rc::clone(&render);
        ui.core.hub.subscribe_widget(&stack, move |_, event| {
            if matches!(
                event,
                AppEvent::WantlistChanged | AppEvent::LibraryReloaded
            ) {
                render();
            }
        });
    }
    {
        let ui = Rc::clone(ui);
        let refreshed_once = Cell::new(false);
        stack.connect_map(move |_| {
            let _ = ui.core.db.acknowledge_wantlist();
            ui.core.hub.emit(&AppEvent::WantlistSeen);
            if !refreshed_once.replace(true) {
                crate::wantlist::refresh(&ui.core);
            }
        });
    }

    stack.upcast()
}

fn toolbar_row(ui: &Rc<Ui>, filter: &Rc<Cell<Filter>>) -> gtk::Widget {
    let row = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(8)
        .build();
    let chips = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(6)
        .hexpand(true)
        .build();
    chips.add_css_class("linked");
    for (value, label) in FILTERS {
        let chip = gtk::ToggleButton::with_label(label);
        chip.add_css_class("chip");
        chip.set_active(filter.get() == value);
        let ui = Rc::clone(ui);
        let filter = Rc::clone(filter);
        chip.connect_clicked(move |chip| {
            if filter.get() == value {
                chip.set_active(true);
                return;
            }
            filter.set(value);
            ui.core.hub.emit(&AppEvent::WantlistChanged);
        });
        chips.append(&chip);
    }
    row.append(&chips);

    let add = gtk::Button::from_icon_name("list-add-symbolic");
    add.set_tooltip_text(Some("Add to wantlist manually"));
    {
        let ui = Rc::clone(ui);
        add.connect_clicked(move |_| prompt_manual_add(&ui));
    }
    row.append(&add);

    let refresh = gtk::Button::from_icon_name("view-refresh-symbolic");
    refresh.set_tooltip_text(Some("Refresh suggestions"));
    {
        let ui = Rc::clone(ui);
        refresh.connect_clicked(move |_| {
            ui.core.toast("Refreshing wantlist…");
            crate::wantlist::refresh(&ui.core);
        });
    }
    row.append(&refresh);
    row.upcast()
}

fn section_title(text: &str) -> gtk::Widget {
    let label = gtk::Label::builder().label(text).xalign(0.0).build();
    label.add_css_class("stat-caption");
    label.upcast()
}

fn section_list() -> gtk::ListBox {
    let list = gtk::ListBox::builder()
        .selection_mode(gtk::SelectionMode::None)
        .build();
    list.add_css_class("boxed-list");
    list
}

fn artwork_widget(
    images: &Rc<RemoteImages>,
    image_url: Option<&str>,
    seed: &str,
) -> gtk::Widget {
    let picture = gtk::Picture::builder()
        .width_request(48)
        .height_request(48)
        .content_fit(gtk::ContentFit::Cover)
        .build();
    picture.set_overflow(gtk::Overflow::Hidden);
    picture.add_css_class("cover");
    let size = 48u32;
    let placeholder = crate::palette::placeholder_rgba(seed, size);
    let texture = gtk::gdk::MemoryTexture::new(
        size as i32,
        size as i32,
        gtk::gdk::MemoryFormat::R8g8b8a8,
        &glib::Bytes::from_owned(placeholder),
        (size * 4) as usize,
    );
    picture.set_paintable(Some(&texture));
    if let Some(url) = image_url {
        let weak = picture.downgrade();
        images.request(url, move |texture| {
            if let (Some(picture), Some(texture)) = (weak.upgrade(), texture) {
                picture.set_paintable(Some(texture));
            }
        });
    }
    picture.upcast()
}

fn row_shell(
    images: &Rc<RemoteImages>,
    image_url: Option<&str>,
    seed: &str,
    title: &str,
    subtitle: &str,
) -> (gtk::Box, gtk::Box) {
    let row_box = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(12)
        .margin_top(8)
        .margin_bottom(8)
        .margin_start(10)
        .margin_end(10)
        .build();
    row_box.append(&artwork_widget(images, image_url, seed));
    let text_box = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(2)
        .hexpand(true)
        .valign(gtk::Align::Center)
        .build();
    let title_label = gtk::Label::builder()
        .label(title)
        .xalign(0.0)
        .ellipsize(pango::EllipsizeMode::End)
        .tooltip_text(title)
        .build();
    title_label.add_css_class("album-title");
    text_box.append(&title_label);
    let subtitle_label = gtk::Label::builder()
        .label(subtitle)
        .xalign(0.0)
        .ellipsize(pango::EllipsizeMode::End)
        .build();
    subtitle_label.add_css_class("dim");
    subtitle_label.add_css_class("caption");
    text_box.append(&subtitle_label);
    row_box.append(&text_box);
    let actions = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(6)
        .valign(gtk::Align::Center)
        .build();
    row_box.append(&actions);
    (row_box, actions)
}

fn wantlist_row(
    ui: &Rc<Ui>,
    images: &Rc<RemoteImages>,
    item: &WantlistItemRow,
) -> gtk::ListBoxRow {
    let title = if item.kind == "artist" {
        item.artist.clone()
    } else {
        item.title.clone()
    };
    let subtitle = if item.kind == "artist" || item.artist == title {
        item.reason.clone()
    } else {
        format!("{} · {}", item.artist, item.reason)
    };
    let (row_box, actions) = row_shell(
        images,
        item.image_url.as_deref(),
        &format!("{}|{}", title, item.artist),
        &title,
        &subtitle,
    );

    let got_it = gtk::Button::from_icon_name("object-select-symbolic");
    got_it.set_tooltip_text(Some("Got it — mark as acquired"));
    {
        let ui = Rc::clone(ui);
        let norm_key = item.norm_key.clone();
        got_it.connect_clicked(move |_| {
            if let Err(err) = ui.core.db.set_wantlist_state(&norm_key, "acquired") {
                crate::logger::error("wantlist", &format!("state write failed: {err}"));
                return;
            }
            ui.core.hub.emit(&AppEvent::WantlistChanged);
        });
    }
    actions.append(&got_it);

    let dismiss = gtk::Button::from_icon_name("window-close-symbolic");
    dismiss.set_tooltip_text(Some("Dismiss — don't suggest again"));
    {
        let ui = Rc::clone(ui);
        let norm_key = item.norm_key.clone();
        dismiss.connect_clicked(move |_| {
            if let Err(err) = ui.core.db.set_wantlist_state(&norm_key, "dismissed") {
                crate::logger::error("wantlist", &format!("state write failed: {err}"));
                return;
            }
            ui.core.hub.emit(&AppEvent::WantlistChanged);
        });
    }
    actions.append(&dismiss);

    let search_url = format!(
        "https://www.last.fm/music/{}",
        url_path_encode(&item.artist)
    );
    let open = gtk::Button::from_icon_name("web-browser-symbolic");
    open.set_tooltip_text(Some("Open on Last.fm"));
    {
        let ui = Rc::clone(ui);
        open.connect_clicked(move |_| open_url(&ui, &search_url));
    }
    actions.append(&open);

    gtk::ListBoxRow::builder()
        .child(&row_box)
        .activatable(false)
        .build()
}

fn release_row(
    ui: &Rc<Ui>,
    images: &Rc<RemoteImages>,
    release: &NewReleaseRow,
) -> gtk::ListBoxRow {
    let released = chrono::DateTime::from_timestamp(release.release_unix, 0)
        .map(|dt| dt.format("%b %-d, %Y").to_string())
        .unwrap_or_default();
    let (row_box, actions) = row_shell(
        images,
        release.image_url.as_deref(),
        &format!("{}|{}", release.album, release.artist),
        &release.album,
        &format!("{} · Released {released}", release.artist),
    );
    if let Some(store_url) = release.store_url.clone() {
        let open = gtk::Button::from_icon_name("web-browser-symbolic");
        open.set_tooltip_text(Some("Open in store"));
        let ui = Rc::clone(ui);
        open.connect_clicked(move |_| open_url(&ui, &store_url));
        actions.append(&open);
    }
    let want = gtk::Button::from_icon_name("list-add-symbolic");
    want.set_tooltip_text(Some("Add to wantlist"));
    {
        let ui = Rc::clone(ui);
        let release = release.clone();
        want.connect_clicked(move |_| {
            let record = WantlistItemRow {
                norm_key: crate::wantlist::norm_key("album", &release.album, &release.artist),
                kind: "album".to_string(),
                title: release.album.clone(),
                artist: release.artist.clone(),
                image_url: release.image_url.clone(),
                source: "manual".to_string(),
                score: 1000.0,
                reason: "Added by you".to_string(),
                play_count: 0,
            };
            if let Err(err) = ui.core.db.merge_wantlist_suggestions(&[record]) {
                crate::logger::error("wantlist", &format!("manual add failed: {err}"));
                return;
            }
            ui.core.toast(&format!("Added {} to wantlist", release.album));
            ui.core.hub.emit(&AppEvent::WantlistChanged);
        });
    }
    actions.append(&want);
    gtk::ListBoxRow::builder()
        .child(&row_box)
        .activatable(false)
        .build()
}

fn prompt_manual_add(ui: &Rc<Ui>) {
    let dialog = adw::AlertDialog::builder()
        .heading("Add to Wantlist")
        .body("Album or song you want to get, and its artist.")
        .build();
    let form = gtk::Box::new(gtk::Orientation::Vertical, 8);
    let title_entry = gtk::Entry::builder().placeholder_text("Title").build();
    let artist_entry = gtk::Entry::builder().placeholder_text("Artist").build();
    let kind_model = gtk::StringList::new(&["Album", "Song"]);
    let kind = gtk::DropDown::builder().model(&kind_model).build();
    form.append(&title_entry);
    form.append(&artist_entry);
    form.append(&kind);
    dialog.set_extra_child(Some(&form));
    dialog.add_response("cancel", "Cancel");
    dialog.add_response("add", "Add");
    dialog.set_response_appearance("add", adw::ResponseAppearance::Suggested);
    let window = ui.window.clone();
    let ui = Rc::clone(ui);
    dialog.connect_response(Some("add"), move |_, _| {
        let title = title_entry.text().trim().to_string();
        let artist = artist_entry.text().trim().to_string();
        if title.is_empty() || artist.is_empty() {
            ui.core.toast("Title and artist are required");
            return;
        }
        let kind = if kind.selected() == 1 { "track" } else { "album" };
        let record = WantlistItemRow {
            norm_key: crate::wantlist::norm_key(kind, &title, &artist),
            kind: kind.to_string(),
            title: title.clone(),
            artist,
            image_url: None,
            source: "manual".to_string(),
            score: 1000.0,
            reason: "Added by you".to_string(),
            play_count: 0,
        };
        if let Err(err) = ui.core.db.merge_wantlist_suggestions(&[record]) {
            crate::logger::error("wantlist", &format!("manual add failed: {err}"));
            return;
        }
        crate::logger::info("wantlist", &format!("manual add: {title}"));
        ui.core.hub.emit(&AppEvent::WantlistChanged);
    });
    dialog.present(Some(&window));
}

fn open_url(ui: &Rc<Ui>, url: &str) {
    gtk::UriLauncher::new(url).launch(
        Some(&ui.window),
        None::<&gtk::gio::Cancellable>,
        |result| {
            if let Err(err) = result {
                crate::logger::warn("ui", &format!("browser launch failed: {err}"));
            }
        },
    );
}

fn url_path_encode(input: &str) -> String {
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

type ImageCallback = Box<dyn Fn(Option<&gtk::gdk::MemoryTexture>)>;

/// Tiny remote-image loader for wantlist artwork: downloads and decodes on a
/// worker thread, caches decoded textures by URL, dedupes in-flight requests.
pub struct RemoteImages {
    cache: RefCell<HashMap<String, gtk::gdk::MemoryTexture>>,
    misses: RefCell<std::collections::HashSet<String>>,
    pending: RefCell<HashMap<String, Vec<ImageCallback>>>,
}

impl RemoteImages {
    pub fn new() -> Self {
        Self {
            cache: RefCell::new(HashMap::new()),
            misses: RefCell::new(std::collections::HashSet::new()),
            pending: RefCell::new(HashMap::new()),
        }
    }

    pub fn request(
        self: &Rc<Self>,
        url: &str,
        callback: impl Fn(Option<&gtk::gdk::MemoryTexture>) + 'static,
    ) {
        if let Some(texture) = self.cache.borrow().get(url) {
            callback(Some(texture));
            return;
        }
        if self.misses.borrow().contains(url) {
            callback(None);
            return;
        }
        let mut pending = self.pending.borrow_mut();
        let entry = pending.entry(url.to_string()).or_default();
        let first = entry.is_empty();
        entry.push(Box::new(callback));
        drop(pending);
        if !first {
            return;
        }
        let (tx, rx) = async_channel::bounded::<Option<(u32, u32, Vec<u8>)>>(1);
        let fetch_url = url.to_string();
        std::thread::Builder::new()
            .name("flaccy-wl-image".into())
            .spawn(move || {
                let _ = tx.send_blocking(fetch_and_decode(&fetch_url));
            })
            .ok();
        let weak = Rc::downgrade(self);
        let url = url.to_string();
        glib::spawn_future_local(async move {
            let decoded = rx.recv().await.ok().flatten();
            let Some(images) = weak.upgrade() else { return };
            let texture = decoded.map(|(width, height, rgba)| {
                gtk::gdk::MemoryTexture::new(
                    width as i32,
                    height as i32,
                    gtk::gdk::MemoryFormat::R8g8b8a8,
                    &glib::Bytes::from_owned(rgba),
                    (width * 4) as usize,
                )
            });
            match &texture {
                Some(texture) => {
                    images.cache.borrow_mut().insert(url.clone(), texture.clone());
                }
                None => {
                    images.misses.borrow_mut().insert(url.clone());
                }
            }
            let callbacks = images.pending.borrow_mut().remove(&url);
            if let Some(callbacks) = callbacks {
                for callback in callbacks {
                    callback(texture.as_ref());
                }
            }
        });
    }
}

fn fetch_and_decode(url: &str) -> Option<(u32, u32, Vec<u8>)> {
    let response = ureq::AgentBuilder::new()
        .timeout(std::time::Duration::from_secs(15))
        .build()
        .get(url)
        .call()
        .ok()?;
    let mut data = Vec::new();
    use std::io::Read;
    response
        .into_reader()
        .take(10 * 1024 * 1024)
        .read_to_end(&mut data)
        .ok()?;
    let decoded = image::load_from_memory(&data).ok()?;
    let thumbnail = decoded.thumbnail(96, 96).to_rgba8();
    let (width, height) = thumbnail.dimensions();
    Some((width, height, thumbnail.into_raw()))
}
