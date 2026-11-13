//! The depth Preferences shares with the iPhone's Settings: the Sound page (the
//! live signal path, the Listening Guide cards for the output in use, the
//! equalizer, every song's own volume and the whole guide), the library
//! overview atop the Library group, and the Home Screen row.

use crate::eq::output::{Output, OutputKind};
use crate::events::AppEvent;
use crate::library::{Library, Track};
use crate::ui::{guide, Ui};
use adw::prelude::*;
use flaccy_library::db::LibraryOverviewTotals;
use flaccy_library::server_sync::song_key_of;
use flaccy_shared::equalizer::song_gain;
use flaccy_shared::home::Layout;
use flaccy_shared::signal_path::{SignalOutputKind, SignalPathVerdict};
use gtk::glib;
use std::cell::{Cell, RefCell};
use std::collections::{HashMap, HashSet};
use std::rc::Rc;

/// The Sound page of Preferences. `dialog` is the Preferences dialog it sits
/// in, which pushes the Song Volumes list and closes on the way to the guide.
pub fn page(ui: &Rc<Ui>, dialog: &adw::PreferencesDialog) -> adw::PreferencesPage {
    let page = adw::PreferencesPage::builder()
        .title("Sound")
        .icon_name("audio-speakers-symbolic")
        .name("sound")
        .build();

    let path = SignalPathCard::new();
    let path_group = adw::PreferencesGroup::new();
    path_group.add(&path.root);
    path_group.add(&footnote(
        "Flaccy sees the file, its own processing and the kind of output. What the device does after that is up to the device.",
    ));
    page.add(&path_group);

    let output_group = adw::PreferencesGroup::builder()
        .title("About This Output")
        .build();
    page.add(&output_group);

    let controls = adw::PreferencesGroup::new();
    let equalizer_row = navigation_row("Equalizer", "flaccy-equalizer-symbolic", "sound-tint-pink");
    let song_volumes_row = navigation_row("Song Volumes", "audio-volume-high-symbolic", "sound-tint-orange");
    controls.add(&equalizer_row);
    controls.add(&song_volumes_row);
    page.add(&controls);

    let guide_group = adw::PreferencesGroup::new();
    let guide_row = navigation_row("Listening Guide", "dialog-information-symbolic", "sound-tint-cyan");
    guide_row.set_subtitle("How Bluetooth, AAC, and lossless files really affect what you hear.");
    guide_group.add(&guide_row);
    page.add(&guide_group);

    let sound = Rc::new(SoundPage {
        ui: Rc::clone(ui),
        dialog: dialog.downgrade(),
        path,
        output_group,
        output_rows: RefCell::new(Vec::new()),
        shown_cards: RefCell::new(None),
        equalizer_row: equalizer_row.clone(),
        song_volumes_row: song_volumes_row.clone(),
        sample_rate: RefCell::new(None),
        rate_asked_for: RefCell::new(None),
        rate_stale: Cell::new(false),
        song_volume_count: Cell::new(None),
    });
    sound.refresh();

    {
        let ui = Rc::clone(ui);
        equalizer_row.connect_activated(move |_| crate::ui::equalizer::present(&ui));
    }
    {
        let ui = Rc::clone(ui);
        let dialog = dialog.downgrade();
        song_volumes_row.connect_activated(move |_| {
            if let Some(dialog) = dialog.upgrade() {
                push_song_volumes(&ui, &dialog);
            }
        });
    }
    {
        let sound = Rc::downgrade(&sound);
        guide_row.connect_activated(move |_| {
            if let Some(sound) = sound.upgrade() {
                sound.open_guide(None);
            }
        });
    }
    {
        let sound = Rc::clone(&sound);
        ui.core.hub.subscribe_widget(&page, move |_, event| {
            if matches!(event, AppEvent::SongGainChanged | AppEvent::LibraryReloaded) {
                sound.song_volume_count.set(None);
            }
            if matches!(
                event,
                AppEvent::TrackChanged(_)
                    | AppEvent::EqualizerChanged
                    | AppEvent::EqualizerOutputChanged { .. }
                    | AppEvent::SongGainChanged
                    | AppEvent::LibraryReloaded
            ) {
                sound.rate_stale.set(true);
                sound.refresh();
            }
        });
    }
    page
}

/// What the Sound page shows and keeps current.
struct SoundPage {
    ui: Rc<Ui>,
    dialog: glib::WeakRef<adw::PreferencesDialog>,
    path: SignalPathCard,
    output_group: adw::PreferencesGroup,
    output_rows: RefCell<Vec<adw::ActionRow>>,
    shown_cards: RefCell<Option<Vec<usize>>>,
    equalizer_row: adw::ActionRow,
    song_volumes_row: adw::ActionRow,
    /// The rate of the sink last read, with that sink's id; `None` inside when
    /// `pactl` could not tell, so a missing `pactl` is asked once per sink.
    sample_rate: RefCell<Option<(String, Option<u32>)>>,
    /// The sink whose rate is being read right now, so a burst of events asks once.
    rate_asked_for: RefCell<Option<String>>,
    /// Set by every event that can come with a new rate on the same sink (a new
    /// song, a new output, an equalizer change), so the next refresh reads it again.
    rate_stale: Cell<bool>,
    /// How many songs in the library have a volume of their own, counted again
    /// after a song volume or the library changes.
    song_volume_count: Cell<Option<usize>>,
}

impl SoundPage {
    fn refresh(self: &Rc<Self>) {
        let track = self.ui.core.player.current_track();
        let running = self.ui.core.eq.running_profile();
        let tenths = track.as_ref().map(|track| self.ui.core.song_gain(track)).unwrap_or(0);
        let output = self.ui.core.eq.output();
        let kind = output.as_ref().map(|output| signal_kind(output.kind));
        let verdict = SignalPathVerdict::of(
            track.as_ref().map(crate::filters::is_lossless),
            running.is_some() || tenths != 0,
            kind,
        );

        match &track {
            Some(track) => self.path.file.show(
                "audio-x-generic-symbolic",
                "sound-tint-cyan",
                &track.quality_badge().unwrap_or_else(|| track.title.clone()),
                Some(&source_detail(track)),
            ),
            None => self.path.file.show(
                "audio-x-generic-symbolic",
                "sound-tint-cyan",
                "Nothing playing",
                Some("Play a song to see how it reaches you."),
            ),
        }
        let untouched = running.is_none() && tenths == 0;
        let mut processing = Vec::new();
        if let Some(profile) = &running {
            processing.push(format!("Equalizer: {}", profile.name));
        }
        if tenths != 0 {
            processing.push(format!("Song volume {}", song_gain::label(tenths)));
        }
        let processing = (!processing.is_empty()).then(|| processing.join(" · "));
        self.path.flaccy.show(
            if untouched { "object-select-symbolic" } else { "flaccy-equalizer-symbolic" },
            if untouched { "sound-tint-green" } else { "sound-tint-blue" },
            if untouched { "Untouched" } else { "Shaped" },
            processing.as_deref(),
        );
        self.path.output.show(
            output_icon(kind),
            "sound-tint-indigo",
            output.as_ref().map(|output| output.name.as_str()).unwrap_or("This device"),
            self.output_detail(output.as_ref(), kind).as_deref(),
        );
        self.path.set_verdict(verdict);

        self.show_guide_cards(SignalPathVerdict::guide_cards(kind));
        self.equalizer_row.set_subtitle(
            &running
                .as_ref()
                .map(|profile| profile.name.clone())
                .unwrap_or_else(|| "Off".to_string()),
        );
        let adjusted = self.song_volume_count();
        self.song_volumes_row.set_subtitle(&if adjusted == 0 {
            "None".to_string()
        } else {
            crate::history_sync::group_thousands(adjusted as i64)
        });
    }

    /// The songs the Song Volumes list shows: in this library, with a volume of
    /// their own. Levels synced from another device for songs this library
    /// lacks are not counted, as the Apple clients count them.
    fn song_volume_count(&self) -> usize {
        if let Some(count) = self.song_volume_count.get() {
            return count;
        }
        let levels = self.ui.core.db.song_gains().unwrap_or_default();
        let count = adjusted_song_count(&self.ui.core.library.borrow(), &levels);
        self.song_volume_count.set(Some(count));
        count
    }

    /// The kind of output and the rate its sink runs at, such as
    /// "Bluetooth · 48 kHz". The rate is read off the main thread when a sink
    /// is first seen and again after any event that can change it, and the page
    /// refreshes once a new value is known.
    fn output_detail(self: &Rc<Self>, output: Option<&Output>, kind: Option<SignalOutputKind>) -> Option<String> {
        let name = kind.and_then(kind_label);
        let rate = output.and_then(|output| {
            let known = self.sample_rate.borrow().clone();
            let cached = match known {
                Some((id, rate)) if id == output.id => Some(rate),
                _ => None,
            };
            if cached.is_none() || self.rate_stale.get() {
                self.ask_sample_rate(&output.id);
            }
            cached.flatten()
        });
        let rate = rate.map(|hertz| format!("{} kHz", format_kilohertz(hertz)));
        let parts: Vec<String> = [name.map(str::to_string), rate].into_iter().flatten().collect();
        (!parts.is_empty()).then(|| parts.join(" · "))
    }

    fn ask_sample_rate(self: &Rc<Self>, id: &str) {
        if self.rate_asked_for.borrow().as_deref() == Some(id) {
            return;
        }
        self.rate_stale.set(false);
        *self.rate_asked_for.borrow_mut() = Some(id.to_string());
        let (sender, receiver) = async_channel::bounded::<Option<u32>>(1);
        let sink = id.to_string();
        let spawned = std::thread::Builder::new()
            .name("flaccy-sink-rate".into())
            .spawn(move || {
                let _ = sender.send_blocking(crate::eq::output::sink_sample_rate(&sink));
            });
        if spawned.is_err() {
            *self.rate_asked_for.borrow_mut() = None;
            return;
        }
        let page = Rc::downgrade(self);
        let id = id.to_string();
        glib::spawn_future_local(async move {
            let rate = receiver.recv().await.ok().flatten();
            let Some(page) = page.upgrade() else { return };
            if page.rate_asked_for.borrow().as_deref() == Some(id.as_str()) {
                *page.rate_asked_for.borrow_mut() = None;
            }
            let changed = page.sample_rate.borrow().as_ref() != Some(&(id.clone(), rate));
            *page.sample_rate.borrow_mut() = Some((id, rate));
            if changed {
                page.refresh();
            }
        });
    }

    /// Lists the guide cards that fit the output, rebuilding the rows only when
    /// the set of cards changes.
    fn show_guide_cards(self: &Rc<Self>, cards: &[usize]) {
        if self.shown_cards.borrow().as_deref() == Some(cards) {
            return;
        }
        for row in self.output_rows.borrow_mut().drain(..) {
            self.output_group.remove(&row);
        }
        for &position in cards {
            let Some((title, icon)) = guide::card_heading(position) else {
                continue;
            };
            let row = navigation_row(title, icon, "sound-tint-cyan");
            row.upcast_ref::<gtk::Widget>().update_property(&[gtk::accessible::Property::Description(
                "Opens this card of the Listening Guide",
            )]);
            let page = Rc::downgrade(self);
            row.connect_activated(move |_| {
                if let Some(page) = page.upgrade() {
                    page.open_guide(Some(position));
                }
            });
            self.output_group.add(&row);
            self.output_rows.borrow_mut().push(row);
        }
        self.output_group.set_visible(!self.output_rows.borrow().is_empty());
        *self.shown_cards.borrow_mut() = Some(cards.to_vec());
    }

    fn open_guide(&self, position: Option<usize>) {
        if let Some(dialog) = self.dialog.upgrade() {
            dialog.close();
        }
        guide::show(&self.ui, position);
    }
}

/// The file's title and how faithful it is, such as "Slow Machine · Lossless, hi-res".
fn source_detail(track: &Track) -> String {
    let hi_res = track.bit_depth.unwrap_or(0) > 16 || track.sample_rate.unwrap_or(0) > 48_000;
    let quality = match (crate::filters::is_lossless(track), hi_res) {
        (true, true) => "Lossless, hi-res",
        (true, false) => "Lossless",
        (false, _) => "Lossy",
    };
    format!("{} · {quality}", track.title)
}

fn signal_kind(kind: OutputKind) -> SignalOutputKind {
    match kind {
        OutputKind::Speaker => SignalOutputKind::Speaker,
        OutputKind::Headphones => SignalOutputKind::Headphones,
        OutputKind::Bluetooth => SignalOutputKind::Bluetooth,
        OutputKind::Usb => SignalOutputKind::Usb,
        OutputKind::Display => SignalOutputKind::Display,
        OutputKind::Other => SignalOutputKind::Other,
    }
}

fn kind_label(kind: SignalOutputKind) -> Option<&'static str> {
    match kind {
        SignalOutputKind::Speaker => Some("Built-in speaker"),
        SignalOutputKind::Headphones => Some("Wired headphones"),
        SignalOutputKind::Bluetooth => Some("Bluetooth"),
        SignalOutputKind::AirPlay => Some("AirPlay"),
        SignalOutputKind::Usb => Some("USB audio"),
        SignalOutputKind::Display => Some("Display"),
        SignalOutputKind::Car => Some("CarPlay"),
        SignalOutputKind::Other => None,
    }
}

fn output_icon(kind: Option<SignalOutputKind>) -> &'static str {
    match kind {
        Some(SignalOutputKind::Headphones) => "audio-headphones-symbolic",
        Some(SignalOutputKind::Bluetooth) => "bluetooth-active-symbolic",
        Some(SignalOutputKind::Usb) => "audio-card-symbolic",
        Some(SignalOutputKind::Display) => "video-display-symbolic",
        _ => "audio-speakers-symbolic",
    }
}

/// "48", "44.1": a rate in kilohertz with a decimal only when it has one.
fn format_kilohertz(hertz: u32) -> String {
    if hertz.is_multiple_of(1000) {
        format!("{}", hertz / 1000)
    } else {
        format!("{:.1}", f64::from(hertz) / 1000.0)
    }
}

fn verdict_tint(verdict: SignalPathVerdict) -> &'static str {
    match verdict {
        SignalPathVerdict::Idle => "sound-tint-faint",
        SignalPathVerdict::Untouched => "sound-tint-green",
        SignalPathVerdict::Shaped => "sound-tint-blue",
        SignalPathVerdict::ReencodedForBluetooth => "sound-tint-orange",
        SignalPathVerdict::LossySource => "sound-tint-gray",
    }
}

const TINTS: [&str; 10] = [
    "sound-tint-cyan",
    "sound-tint-green",
    "sound-tint-blue",
    "sound-tint-indigo",
    "sound-tint-orange",
    "sound-tint-gray",
    "sound-tint-faint",
    "sound-tint-pink",
    "sound-tint-purple",
    "sound-tint-teal",
];

/// Gives `widget` the tint class `tint` and no other.
fn set_tint(widget: &impl IsA<gtk::Widget>, tint: &str) {
    for class in TINTS {
        if class != tint {
            widget.remove_css_class(class);
        }
    }
    widget.add_css_class(tint);
}

/// A small coloured tile holding a symbolic icon, the way each row of the
/// Apple Settings leads.
fn icon_tile(icon: &str, tint: &str) -> gtk::Image {
    let image = gtk::Image::from_icon_name(icon);
    image.set_pixel_size(16);
    image.set_valign(gtk::Align::Center);
    image.add_css_class("sound-tile");
    set_tint(&image, tint);
    image
}

/// A row that opens something, led by an icon tile and ended by a chevron.
fn navigation_row(title: &str, icon: &str, tint: &str) -> adw::ActionRow {
    let row = adw::ActionRow::builder()
        .title(title)
        .use_markup(false)
        .activatable(true)
        .build();
    row.add_prefix(&icon_tile(icon, tint));
    row.add_suffix(&gtk::Image::from_icon_name("go-next-symbolic"));
    row
}

fn footnote(text: &str) -> gtk::Label {
    let label = gtk::Label::builder()
        .label(text)
        .xalign(0.0)
        .wrap(true)
        .margin_top(8)
        .margin_start(6)
        .margin_end(6)
        .build();
    label.add_css_class("caption");
    label.add_css_class("dim");
    label
}

/// The file, Flaccy and the output as three joined stages, then the verdict.
struct SignalPathCard {
    root: gtk::Box,
    file: Stage,
    flaccy: Stage,
    output: Stage,
    verdict_dot: gtk::Box,
    verdict: gtk::Label,
}

impl SignalPathCard {
    fn new() -> SignalPathCard {
        let root = gtk::Box::new(gtk::Orientation::Vertical, 0);
        root.add_css_class("card");
        root.add_css_class("sound-path");
        let file = Stage::new("File");
        let flaccy = Stage::new("Flaccy");
        let output = Stage::new("Output");
        root.append(&file.root);
        root.append(&connector());
        root.append(&flaccy.root);
        root.append(&connector());
        root.append(&output.root);
        let separator = gtk::Separator::new(gtk::Orientation::Horizontal);
        separator.add_css_class("sound-path-separator");
        root.append(&separator);
        let verdict_line = gtk::Box::new(gtk::Orientation::Horizontal, 10);
        let verdict_dot = gtk::Box::new(gtk::Orientation::Horizontal, 0);
        verdict_dot.add_css_class("sound-verdict-dot");
        verdict_dot.set_valign(gtk::Align::Center);
        let verdict = gtk::Label::builder().xalign(0.0).wrap(true).hexpand(true).build();
        verdict.add_css_class("sound-verdict");
        verdict_line.append(&verdict_dot);
        verdict_line.append(&verdict);
        root.append(&verdict_line);
        SignalPathCard { root, file, flaccy, output, verdict_dot, verdict }
    }

    fn set_verdict(&self, verdict: SignalPathVerdict) {
        set_tint(&self.verdict_dot, verdict_tint(verdict));
        self.verdict.set_label(verdict.sentence());
    }
}

/// The short line joining two stages, centred under their tiles.
fn connector() -> gtk::Box {
    let line = gtk::Box::new(gtk::Orientation::Vertical, 0);
    line.add_css_class("sound-connector");
    line.set_halign(gtk::Align::Start);
    line
}

/// One stage of the path: a tile, a small caption and what the stage is doing.
struct Stage {
    root: gtk::Box,
    tile: gtk::Image,
    title: gtk::Label,
    detail: gtk::Label,
}

impl Stage {
    fn new(caption: &str) -> Stage {
        let root = gtk::Box::new(gtk::Orientation::Horizontal, 12);
        let tile = icon_tile("audio-x-generic-symbolic", "sound-tint-cyan");
        tile.set_valign(gtk::Align::Start);
        let text = gtk::Box::new(gtk::Orientation::Vertical, 1);
        text.set_hexpand(true);
        let caption_label = gtk::Label::builder().label(caption.to_uppercase()).xalign(0.0).build();
        caption_label.add_css_class("sound-caption");
        let title = gtk::Label::builder().xalign(0.0).wrap(true).build();
        title.add_css_class("heading");
        let detail = gtk::Label::builder().xalign(0.0).wrap(true).build();
        detail.add_css_class("caption");
        detail.add_css_class("dim");
        text.append(&caption_label);
        text.append(&title);
        text.append(&detail);
        root.append(&tile);
        root.append(&text);
        Stage { root, tile, title, detail }
    }

    fn show(&self, icon: &str, tint: &str, title: &str, detail: Option<&str>) {
        self.tile.set_icon_name(Some(icon));
        set_tint(&self.tile, tint);
        self.title.set_label(title);
        self.detail.set_label(detail.unwrap_or(""));
        self.detail.set_visible(detail.is_some_and(|detail| !detail.is_empty()));
    }
}

/// How many songs in the library have a volume of their own, one per song.
fn adjusted_song_count(library: &Library, levels: &HashMap<String, i32>) -> usize {
    if levels.is_empty() {
        return 0;
    }
    let mut seen = HashSet::new();
    library
        .tracks
        .iter()
        .filter(|track| {
            let key = song_key_of(&track.title, &track.artist);
            levels.contains_key(&key) && seen.insert(key)
        })
        .count()
}

/// Every song with a volume of its own, one copy per song, by title.
fn adjusted_songs(library: &Library, levels: &HashMap<String, i32>) -> Vec<(Track, i32)> {
    if levels.is_empty() {
        return Vec::new();
    }
    let mut seen = HashSet::new();
    let mut songs: Vec<(Track, i32)> = library
        .tracks
        .iter()
        .filter_map(|track| {
            let key = song_key_of(&track.title, &track.artist);
            let tenths = *levels.get(&key)?;
            seen.insert(key).then(|| (track.clone(), tenths))
        })
        .collect();
    songs.sort_by(|a, b| {
        a.0.title
            .to_lowercase()
            .cmp(&b.0.title.to_lowercase())
            .then_with(|| a.0.artist.to_lowercase().cmp(&b.0.artist.to_lowercase()))
    });
    songs
}

/// Pushes the Song Volumes list onto the Preferences dialog: every song with a
/// volume of its own, each with its level and a reset, and Reset All.
pub fn push_song_volumes(ui: &Rc<Ui>, dialog: &adw::PreferencesDialog) {
    let group = adw::PreferencesGroup::builder()
        .description("Set a song's own volume from Now Playing. Reset one here to put it back.")
        .build();
    let reset_all = gtk::Button::builder().label("Reset All").build();
    reset_all.add_css_class("destructive-action");
    let header = adw::HeaderBar::new();
    header.pack_end(&reset_all);
    let preferences = adw::PreferencesPage::new();
    preferences.add(&group);
    let toolbar = adw::ToolbarView::new();
    toolbar.add_top_bar(&header);
    toolbar.set_content(Some(&preferences));
    let subpage = adw::NavigationPage::builder()
        .title("Song Volumes")
        .tag("song-volumes")
        .child(&toolbar)
        .build();

    let list = Rc::new(SongVolumeList {
        ui: Rc::clone(ui),
        group,
        rows: RefCell::new(Vec::new()),
        songs: RefCell::new(Vec::new()),
        reset_all: reset_all.clone(),
        resetting: Cell::new(false),
    });
    list.fill();
    {
        let list = Rc::downgrade(&list);
        reset_all.connect_clicked(move |button| {
            if let Some(list) = list.upgrade() {
                list.confirm_reset_all(button);
            }
        });
    }
    {
        let list = Rc::clone(&list);
        ui.core.hub.subscribe_widget(&subpage, move |_, event| {
            if matches!(event, AppEvent::SongGainChanged | AppEvent::LibraryReloaded) && !list.resetting.get() {
                list.fill();
            }
        });
    }
    dialog.push_subpage(&subpage);
}

struct SongVolumeList {
    ui: Rc<Ui>,
    group: adw::PreferencesGroup,
    rows: RefCell<Vec<adw::ActionRow>>,
    songs: RefCell<Vec<Track>>,
    reset_all: gtk::Button,
    /// Set while Reset All writes, so each song's own change event does not
    /// rebuild the list once per song.
    resetting: Cell<bool>,
}

impl SongVolumeList {
    fn fill(self: &Rc<Self>) {
        for row in self.rows.borrow_mut().drain(..) {
            self.group.remove(&row);
        }
        let levels = self.ui.core.db.song_gains().unwrap_or_default();
        let library = self.ui.core.library.borrow().clone();
        let songs = adjusted_songs(&library, &levels);
        self.reset_all.set_sensitive(!songs.is_empty());
        if songs.is_empty() {
            let row = adw::ActionRow::builder()
                .title("Every song plays at its own level")
                .use_markup(false)
                .build();
            row.add_css_class("dim");
            self.group.add(&row);
            self.rows.borrow_mut().push(row);
        }
        for (track, tenths) in &songs {
            let row = adw::ActionRow::builder()
                .title(track.title.as_str())
                .subtitle(track.artist.as_str())
                .use_markup(false)
                .build();
            let level = gtk::Label::new(Some(&song_gain::label(*tenths)));
            level.add_css_class("numeric");
            level.add_css_class(if *tenths > 0 { "sound-level-raised" } else { "dim" });
            row.add_suffix(&level);
            let reset = gtk::Button::from_icon_name("edit-undo-symbolic");
            reset.set_valign(gtk::Align::Center);
            reset.add_css_class("flat");
            reset.set_tooltip_text(Some("Reset"));
            reset.update_property(&[gtk::accessible::Property::Label(&format!(
                "Reset the volume of {}",
                track.title
            ))]);
            {
                let list = Rc::downgrade(self);
                let track = track.clone();
                reset.connect_clicked(move |_| {
                    if let Some(list) = list.upgrade() {
                        list.reset(std::slice::from_ref(&track));
                    }
                });
            }
            row.add_suffix(&reset);
            self.group.add(&row);
            self.rows.borrow_mut().push(row);
        }
        *self.songs.borrow_mut() = songs.into_iter().map(|(track, _)| track).collect();
    }

    fn confirm_reset_all(self: &Rc<Self>, anchor: &gtk::Button) {
        if self.songs.borrow().is_empty() {
            return;
        }
        let alert = adw::AlertDialog::builder()
            .heading("Reset All Song Volumes?")
            .body("Every song plays at the level it was mastered at again.")
            .close_response("cancel")
            .default_response("cancel")
            .build();
        alert.add_response("cancel", "Cancel");
        alert.add_response("reset", "Reset All");
        alert.set_response_appearance("reset", adw::ResponseAppearance::Destructive);
        let list = Rc::downgrade(self);
        alert.connect_response(None, move |_, response| {
            if response != "reset" {
                return;
            }
            if let Some(list) = list.upgrade() {
                let songs = list.songs.borrow().clone();
                list.reset(&songs);
            }
        });
        alert.present(Some(anchor));
    }

    fn reset(self: &Rc<Self>, tracks: &[Track]) {
        self.resetting.set(true);
        let failed = tracks
            .iter()
            .filter(|track| self.ui.core.set_song_gain(track, 0) != 0)
            .count();
        self.resetting.set(false);
        if failed > 0 {
            self.ui.core.toast("A song volume couldn't be reset. Try again.");
        }
        self.fill();
    }
}

/// The library by the numbers, a row of its own atop the Library group:
/// artists, hours and size on this computer, the formats as one bar, and how
/// much of it is lossless and hi-res. It is read off the main thread and again
/// whenever the library changes.
pub fn library_overview_row(ui: &Rc<Ui>) -> adw::PreferencesRow {
    let card = OverviewCard::new();
    let row = adw::PreferencesRow::builder()
        .activatable(false)
        .focusable(false)
        .child(&card.root)
        .build();
    row.upcast_ref::<gtk::Widget>()
        .update_property(&[gtk::accessible::Property::Label("Library overview")]);
    let card = Rc::new(card);
    let loader = Rc::new(OverviewLoader {
        db_path: ui.core.db_path.clone(),
        card: Rc::clone(&card),
        ui: Rc::clone(ui),
        in_flight: Cell::new(false),
        stale: Cell::new(false),
    });
    loader.load();
    if std::env::var("FLACCY_DEMO_PREFS").as_deref() == Ok("library") {
        scroll_into_view_when_shown(&row);
    }
    ui.core.hub.subscribe_widget(&row, move |_, event| {
        if matches!(event, AppEvent::LibraryReloaded | AppEvent::ScanFinished { .. }) {
            loader.load();
        }
    });
    row
}

/// Demo screenshots: scrolls the page holding `row` until the row sits near
/// the top, once the page has been laid out.
fn scroll_into_view_when_shown(row: &adw::PreferencesRow) {
    let row = row.downgrade();
    let attempts = Cell::new(0);
    glib::timeout_add_local(std::time::Duration::from_millis(100), move || {
        attempts.set(attempts.get() + 1);
        let Some(row) = row.upgrade() else {
            return glib::ControlFlow::Break;
        };
        let scroll = row
            .ancestor(gtk::ScrolledWindow::static_type())
            .and_downcast::<gtk::ScrolledWindow>();
        let point = scroll.as_ref().and_then(|scroll| {
            row.compute_point(scroll, &gtk::graphene::Point::new(0.0, 0.0))
        });
        match (scroll, point) {
            (Some(scroll), Some(point)) if scroll.height() > 0 => {
                let adjustment = scroll.vadjustment();
                adjustment.set_value(adjustment.value() + f64::from(point.y()) - 64.0);
                glib::ControlFlow::Break
            }
            _ if attempts.get() > 50 => glib::ControlFlow::Break,
            _ => glib::ControlFlow::Continue,
        }
    });
}

struct OverviewLoader {
    db_path: std::path::PathBuf,
    card: Rc<OverviewCard>,
    ui: Rc<Ui>,
    in_flight: Cell<bool>,
    stale: Cell<bool>,
}

impl OverviewLoader {
    fn load(self: &Rc<Self>) {
        if self.in_flight.replace(true) {
            self.stale.set(true);
            return;
        }
        let db_path = self.db_path.clone();
        let (sender, receiver) = async_channel::bounded::<LibraryOverviewTotals>(1);
        let spawned = std::thread::Builder::new()
            .name("flaccy-library-overview".into())
            .spawn(move || {
                let totals = crate::db::Db::open(&db_path)
                    .map(|db| db.library_overview())
                    .unwrap_or_default();
                let _ = sender.send_blocking(totals);
            });
        if spawned.is_err() {
            self.in_flight.set(false);
            return;
        }
        let loader = Rc::clone(self);
        glib::spawn_future_local(async move {
            let totals = receiver.recv().await.unwrap_or_default();
            loader.in_flight.set(false);
            let artists = loader.ui.core.library.borrow().artists.len();
            loader.card.show(&totals, artists);
            if loader.stale.replace(false) {
                loader.load();
            }
        });
    }
}

/// A format's share as the Apple clients print it: whole percent, ties to even.
fn legend_percent(fraction: f64) -> i64 {
    (fraction * 100.0).round_ties_even() as i64
}

/// A size in the units Finder and the Apple clients use (1 GB = 10^9 bytes):
/// whole kilobytes, megabytes to one decimal, larger units to two, trailing
/// zeros dropped.
fn format_decimal_bytes(bytes: u64) -> String {
    const UNITS: [(&str, u64, usize); 4] = [
        ("TB", 1_000_000_000_000, 2),
        ("GB", 1_000_000_000, 2),
        ("MB", 1_000_000, 1),
        ("KB", 1_000, 0),
    ];
    for (unit, size, decimals) in UNITS {
        if bytes >= size {
            let value = format!("{:.*}", decimals, bytes as f64 / size as f64);
            let value = if value.contains('.') {
                value.trim_end_matches('0').trim_end_matches('.').to_string()
            } else {
                value
            };
            return format!("{value} {unit}");
        }
    }
    format!("{bytes} bytes")
}

/// How many formats the bar names before the rest become "Other".
const NAMED_FORMATS: usize = 4;

/// The formats as shares of the library, the largest four by name and the rest
/// as "Other".
fn format_shares(totals: &LibraryOverviewTotals) -> Vec<(String, f64)> {
    if totals.tracks == 0 {
        return Vec::new();
    }
    let total = totals.tracks as f64;
    let mut shares: Vec<(String, f64)> = totals
        .codecs
        .iter()
        .take(NAMED_FORMATS)
        .map(|(codec, count)| (codec.clone(), *count as f64 / total))
        .collect();
    let rest: usize = totals.codecs.iter().skip(NAMED_FORMATS).map(|(_, count)| count).sum();
    if rest > 0 {
        shares.push(("Other".to_string(), rest as f64 / total));
    }
    shares
}

fn format_color(codec: &str) -> (f64, f64, f64) {
    match codec {
        "FLAC" => (0.196, 0.678, 0.902),
        "ALAC" => (0.188, 0.690, 0.780),
        "WAV" => (0.369, 0.361, 0.902),
        "AIFF" => (0.749, 0.353, 0.949),
        "MP3" => (1.0, 0.624, 0.039),
        "AAC" => (1.0, 0.216, 0.373),
        _ => (0.557, 0.557, 0.576),
    }
}

struct OverviewCard {
    root: gtk::Box,
    artists: gtk::Label,
    hours: gtk::Label,
    size: gtk::Label,
    bar: gtk::DrawingArea,
    shares: Rc<RefCell<Vec<(String, f64)>>>,
    legend: gtk::Box,
    tags: gtk::Box,
}

impl OverviewCard {
    fn new() -> OverviewCard {
        let root = gtk::Box::new(gtk::Orientation::Vertical, 12);
        root.add_css_class("library-overview");
        let numbers = gtk::Box::new(gtk::Orientation::Horizontal, 0);
        numbers.set_homogeneous(true);
        let (artists_column, artists) = number_column("Artists");
        let (hours_column, hours) = number_column("Hours");
        let (size_column, size) = number_column("On Disk");
        numbers.append(&artists_column);
        numbers.append(&hours_column);
        numbers.append(&size_column);
        root.append(&numbers);

        let shares: Rc<RefCell<Vec<(String, f64)>>> = Rc::new(RefCell::new(Vec::new()));
        let bar = gtk::DrawingArea::builder().content_height(10).hexpand(true).build();
        {
            let shares = Rc::clone(&shares);
            bar.set_draw_func(move |_, context, width, height| {
                draw_format_bar(context, f64::from(width), f64::from(height), &shares.borrow());
            });
        }
        root.append(&bar);
        let legend = gtk::Box::new(gtk::Orientation::Horizontal, 14);
        root.append(&legend);
        let tags = gtk::Box::new(gtk::Orientation::Horizontal, 6);
        root.append(&tags);
        OverviewCard { root, artists, hours, size, bar, shares, legend, tags }
    }

    fn show(&self, totals: &LibraryOverviewTotals, artists: usize) {
        let group = crate::history_sync::group_thousands;
        self.artists.set_label(&group(artists as i64));
        self.hours.set_label(&group((totals.seconds / 3600.0).round() as i64));
        self.size.set_label(&if totals.local_bytes > 0 {
            format_decimal_bytes(totals.local_bytes as u64)
        } else {
            "—".to_string()
        });

        let shares = format_shares(totals);
        self.bar.set_visible(!shares.is_empty());
        self.legend.set_visible(!shares.is_empty());
        while let Some(child) = self.legend.first_child() {
            self.legend.remove(&child);
        }
        for (codec, fraction) in &shares {
            let entry = gtk::Box::new(gtk::Orientation::Horizontal, 5);
            let swatch = gtk::Box::new(gtk::Orientation::Horizontal, 0);
            swatch.add_css_class("sound-verdict-dot");
            swatch.add_css_class(&format!("format-{}", codec_class(codec)));
            swatch.set_valign(gtk::Align::Center);
            let label = gtk::Label::new(Some(&format!("{codec} {}%", legend_percent(*fraction))));
            label.add_css_class("caption");
            label.add_css_class("dim");
            entry.append(&swatch);
            entry.append(&label);
            self.legend.append(&entry);
        }
        *self.shares.borrow_mut() = shares;
        self.bar.queue_draw();

        while let Some(child) = self.tags.first_child() {
            self.tags.remove(&child);
        }
        self.tags.set_visible(totals.tracks > 0);
        if totals.tracks > 0 {
            let percent = (totals.lossless_share() * 100.0).round() as i64;
            self.tags.append(&tag(&format!("{percent}% lossless"), "overview-tag-lossless"));
            if totals.hi_res > 0 {
                self.tags.append(&tag(&format!("{} hi-res", group(totals.hi_res as i64)), "overview-tag-hires"));
            }
            if totals.server_tracks > 0 {
                self.tags.append(&tag(
                    &format!("{} from servers", group(totals.server_tracks as i64)),
                    "overview-tag-plain",
                ));
            }
        }
    }
}

/// The CSS name of a codec's colour; codecs without one share the grey.
fn codec_class(codec: &str) -> &'static str {
    match codec {
        "FLAC" => "flac",
        "ALAC" => "alac",
        "WAV" => "wav",
        "AIFF" => "aiff",
        "MP3" => "mp3",
        "AAC" => "aac",
        _ => "other",
    }
}

fn number_column(caption: &str) -> (gtk::Box, gtk::Label) {
    let column = gtk::Box::new(gtk::Orientation::Vertical, 2);
    let value = gtk::Label::new(Some("—"));
    value.add_css_class("stat-value");
    let caption = gtk::Label::new(Some(caption));
    caption.add_css_class("stat-caption");
    column.append(&value);
    column.append(&caption);
    (column, value)
}

fn tag(text: &str, class: &str) -> gtk::Label {
    let label = gtk::Label::new(Some(text));
    label.add_css_class("overview-tag");
    label.add_css_class(class);
    label
}

/// A rounded bar split into coloured segments by share, on a faint track.
fn draw_format_bar(context: &gtk::cairo::Context, width: f64, height: f64, shares: &[(String, f64)]) {
    let radius = height / 2.0;
    rounded_rectangle(context, 0.0, 0.0, width, height, radius);
    context.clip();
    context.set_source_rgba(0.5, 0.5, 0.5, 0.18);
    context.paint().ok();
    let mut x = 0.0;
    for (codec, fraction) in shares {
        let segment = width * fraction;
        let (red, green, blue) = format_color(codec);
        context.set_source_rgb(red, green, blue);
        context.rectangle(x, 0.0, segment, height);
        context.fill().ok();
        x += segment;
    }
}

fn rounded_rectangle(context: &gtk::cairo::Context, x: f64, y: f64, width: f64, height: f64, radius: f64) {
    use std::f64::consts::{FRAC_PI_2, PI};
    context.new_sub_path();
    context.arc(x + width - radius, y + radius, radius, -FRAC_PI_2, 0.0);
    context.arc(x + width - radius, y + height - radius, radius, 0.0, FRAC_PI_2);
    context.arc(x + radius, y + height - radius, radius, FRAC_PI_2, PI);
    context.arc(x + radius, y + radius, radius, PI, 3.0 * FRAC_PI_2);
    context.close_path();
}

/// The Home Screen row of the Appearance group: how many sections Home shows,
/// opening the editor that orders and hides them.
pub fn home_screen_row(ui: &Rc<Ui>) -> adw::ActionRow {
    let row = navigation_row("Home Screen", "go-home-symbolic", "sound-tint-orange");
    let subtitle = {
        let ui = Rc::clone(ui);
        move |row: &adw::ActionRow| {
            let layout = Layout::decode(Some(&ui.core.config.borrow().home_layout));
            let count = layout.visible().len();
            row.set_subtitle(&if count == 1 {
                "1 section".to_string()
            } else {
                format!("{count} sections")
            });
        }
    };
    subtitle(&row);
    {
        let ui = Rc::clone(ui);
        row.connect_activated(move |_| crate::ui::home_customize::present(&ui));
    }
    ui.core.hub.subscribe_widget(&row, move |row, event| {
        if matches!(event, AppEvent::HomeChanged) {
            subtitle(row);
        }
    });
    row
}

/// Demo hooks for screenshots: seeds three songs with volumes of their own
/// when the demo library has none, so the list and the shaped path have
/// something to show.
pub fn seed_demo_song_volumes(ui: &Rc<Ui>) {
    let already = ui.core.db.song_gains().map(|levels| !levels.is_empty()).unwrap_or(true);
    if already {
        return;
    }
    let tracks: Vec<Track> = ui.core.library.borrow().tracks.iter().take(3).cloned().collect();
    for (track, tenths) in tracks.iter().zip([35, -20, 15]) {
        ui.core.set_song_gain(track, tenths);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn totals(codecs: &[(&str, usize)]) -> LibraryOverviewTotals {
        LibraryOverviewTotals {
            tracks: codecs.iter().map(|(_, count)| count).sum(),
            codecs: codecs.iter().map(|(codec, count)| (codec.to_string(), *count)).collect(),
            ..LibraryOverviewTotals::default()
        }
    }

    #[test]
    fn four_formats_are_named_and_the_rest_are_other() {
        let shares = format_shares(&totals(&[
            ("FLAC", 50),
            ("MP3", 20),
            ("ALAC", 10),
            ("AAC", 10),
            ("WAV", 6),
            ("?", 4),
        ]));
        let names: Vec<&str> = shares.iter().map(|(codec, _)| codec.as_str()).collect();
        assert_eq!(names, ["FLAC", "MP3", "ALAC", "AAC", "Other"]);
        assert!((shares[4].1 - 0.10).abs() < 1e-9);
        assert!((shares.iter().map(|(_, share)| share).sum::<f64>() - 1.0).abs() < 1e-9);
    }

    #[test]
    fn an_empty_library_has_no_bar() {
        assert!(format_shares(&totals(&[])).is_empty());
    }

    #[test]
    fn sizes_read_like_the_apple_clients() {
        assert_eq!(format_decimal_bytes(500_000_000_000), "500 GB");
        assert_eq!(format_decimal_bytes(73_400_000_000), "73.4 GB");
        assert_eq!(format_decimal_bytes(46_123_456), "46.1 MB");
        assert_eq!(format_decimal_bytes(1_234_567_890_123), "1.23 TB");
        assert_eq!(format_decimal_bytes(999), "999 bytes");
    }

    #[test]
    fn legend_shares_round_ties_to_even() {
        assert_eq!(legend_percent(0.125), 12);
        assert_eq!(legend_percent(0.025), 2);
        assert_eq!(legend_percent(0.135), 14);
    }

    #[test]
    fn rates_read_in_kilohertz() {
        assert_eq!(format_kilohertz(48_000), "48");
        assert_eq!(format_kilohertz(44_100), "44.1");
        assert_eq!(format_kilohertz(192_000), "192");
    }
}
