use crate::events::AppEvent;
use crate::musicvideo::playback::StageState;
use crate::ui::comments_panel;
use crate::ui::controls::{
    apply_repeat, attach_label_nav, build_volume_control, set_love_appearance,
};
use crate::ui::lyrics_panel::{self, LyricsOptions, Presentation};
use crate::ui::queue_panel::{self, QueueOptions};
use crate::ui::seek_bar;
use crate::ui::slider::SliderMetrics;
use crate::ui::stage_layout::{Arrangement, LyricsStyle, Placement, Side, DEFAULT_ASPECT};
use crate::ui::video_stage::{Layer, VideoStage};
use crate::ui::video_view::{self, VideoView};
use crate::ui::Ui;
use adw::prelude::*;
use crate::library::Track;
use flaccy_shared::track_revision::copy;
use gtk::gdk;
use gtk::glib;
use gtk::pango;
use std::cell::{Cell, RefCell};
use std::rc::Rc;
use std::time::Duration;

/// The skip buttons either side of previous/next, matching the ±15 s the
/// iPhone and Mac players offer, and the Shift+←/→ shortcuts.
pub const SKIP_SECONDS: f64 = 15.0;
/// The dock's side padding plus some slack: an optional control only comes
/// back once it fits with room to spare, so the dock never flickers at the edge.
const DOCK_CHROME: i32 = 64;
/// How long the header, the dock and the pointer stay up over a playing video
/// after the pointer last moved.
const CHROME_LINGER: Duration = Duration::from_millis(2500);
/// How long the title card stays up after a song starts on the stage.
const CARD_HOLD: Duration = Duration::from_secs(6);
/// The logical size the stage's cover is decoded at: its largest drawn size.
const COVER_SIZE: u32 = 600;
/// Below this width only one panel stays open beside the lyrics.
const ONE_PANEL_WIDTH: i32 = 640;

/// Full-window "focus" player pushed onto the outer nav (ui.shell): one stage
/// for every song. The music video, found and synced to the lossless file on
/// its own, fills it as far as the window allows, with its glow around it;
/// until its first frame, and for a song that has none, the cover stands in
/// its place, square, with the title under it, and opens out into the video
/// once it plays. Lyrics, and Up Next or the video's Comments (one side
/// panel, two toggles), are laid beside, under or over the picture, the side
/// they keep to is an option, and the header and dock float over a playing
/// video and step out of the way while the pointer rests. The artist and
/// album labels navigate to their library pages.
pub fn present(ui: &Rc<Ui>) {
    if ui
        .shell
        .visible_page()
        .and_then(|page| page.tag())
        .as_deref()
        == Some("now-playing")
    {
        return;
    }

    let backdrop = gtk::Picture::builder()
        .content_fit(gtk::ContentFit::Cover)
        .hexpand(true)
        .vexpand(true)
        .build();
    backdrop.add_css_class("np-backdrop");

    let scrim = gtk::Box::new(gtk::Orientation::Vertical, 0);
    scrim.add_css_class("np-scrim");
    scrim.set_hexpand(true);
    scrim.set_vexpand(true);

    let cover = gtk::Picture::builder()
        .content_fit(gtk::ContentFit::Cover)
        .build();
    cover.set_overflow(gtk::Overflow::Hidden);
    cover.add_css_class("np-poster");

    let seek = seek_bar::build(ui, SliderMetrics::HERO);
    let transport = TransportControls::new(ui);
    let volume = build_volume_control(ui);

    let current_rel: Rc<RefCell<Option<String>>> = Rc::new(RefCell::new(None));
    {
        let ui = Rc::clone(ui);
        let current_rel = Rc::clone(&current_rel);
        transport.love.connect_clicked(move |_| {
            if let Some(rel) = current_rel.borrow().clone() {
                ui.core.toggle_love(&rel);
            }
        });
    }

    let lyrics = lyrics_panel::build(ui, LyricsOptions::in_view());
    lyrics.widget.add_css_class("np-view");
    lyrics.widget.add_css_class("np-stage-lyrics");

    let queue = queue_panel::build(ui, QueueOptions::in_view());
    queue.widget.add_css_class("np-view");
    let comments = comments_panel::build(ui);
    comments.widget.add_css_class("np-view");
    let side = gtk::Stack::builder()
        .transition_type(gtk::StackTransitionType::Crossfade)
        .transition_duration(160)
        .hhomogeneous(false)
        .vhomogeneous(false)
        .build();
    side.add_css_class("np-view");
    side.add_css_class("np-stage-queue");
    side.add_named(&queue.widget, Some("queue"));
    side.add_named(&comments.widget, Some("comments"));

    let video = video_view::build(ui);
    let card = title_card(ui);
    let stage = VideoStage::default();
    stage.set_zoom(crate::ui::ui_scale::current());
    stage.set_layer(Layer::Ambient, Some(&video.ambient));
    stage.set_layer(Layer::Poster, Some(&cover));
    stage.set_layer(Layer::Video, Some(&video.picture));
    stage.set_layer(Layer::Status, Some(&video.status));
    stage.set_layer(Layer::Lyrics, Some(&lyrics.widget));
    stage.set_layer(Layer::Card, Some(&card.widget));
    stage.set_layer(Layer::Queue, Some(&side));
    stage.set_picture(true, 1.0);

    // Suppresses the config write while the view restores saved panels or the
    // width adaptation folds one away, so a narrow window never overwrites the
    // panel layout the user actually chose.
    let syncing = Rc::new(Cell::new(true));

    let (lyrics_toggle, _) = toggle_button("format-justify-center-symbolic", "Lyrics");
    let (queue_toggle, queue_label) = toggle_button("view-list-symbolic", "Up Next");
    let (comments_toggle, _) = toggle_button("flaccy-comments-symbolic", "Comments");
    comments_toggle.set_tooltip_text(Some("What people say under the song\u{2019}s music video"));
    comments_toggle.set_visible(crate::musicvideo::available());

    let fullscreen = gtk::Button::from_icon_name("view-fullscreen-symbolic");
    fullscreen.add_css_class("flat");
    fullscreen.set_tooltip_text(Some("Full Screen (F11)"));

    let toggles = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    toggles.set_halign(gtk::Align::Center);
    toggles.add_css_class("np-toggles");
    toggles.append(&lyrics_toggle);
    toggles.append(&queue_toggle);
    toggles.append(&comments_toggle);

    let controls_row = gtk::CenterBox::new();
    controls_row.set_center_widget(Some(&transport.container));
    controls_row.set_end_widget(Some(&volume.container));

    let np_transport = gtk::Box::new(gtk::Orientation::Vertical, 10);
    np_transport.add_css_class("np-transport");
    np_transport.append(&seek.container);
    np_transport.append(&controls_row);

    let header = adw::HeaderBar::builder()
        .title_widget(&toggles)
        .show_end_title_buttons(true)
        .build();
    header.add_css_class("flat");
    header.pack_end(&fullscreen);
    header.pack_end(&video.tools);

    let toolbar = adw::ToolbarView::new();
    toolbar.add_css_class("np-toolbar");
    toolbar.set_top_bar_style(adw::ToolbarStyle::Flat);
    toolbar.set_extend_content_to_top_edge(true);
    toolbar.set_extend_content_to_bottom_edge(true);
    toolbar.add_top_bar(&header);
    toolbar.set_content(Some(&stage));
    toolbar.add_bottom_bar(&np_transport);

    let overlay = gtk::Overlay::new();
    overlay.add_css_class("np-root");
    overlay.set_child(Some(&backdrop));
    overlay.add_overlay(&scrim);
    overlay.add_overlay(&toolbar);
    overlay.add_overlay(&seek.bubble);
    overlay.add_overlay(&volume.bubble);

    let chrome = StageChrome::new(
        ui,
        &toolbar,
        [header.upcast_ref(), np_transport.upcast_ref(), side.upcast_ref()],
        &stage,
        &card,
        &video,
    );
    chrome.install(&overlay);

    let layout = Rc::new(Layout {
        ui: Rc::clone(ui),
        stage: stage.clone(),
        toolbar: toolbar.clone(),
        side: side.clone(),
        lyrics_toggle: lyrics_toggle.clone(),
        queue_toggle: queue_toggle.clone(),
        comments_toggle: comments_toggle.clone(),
        set_presentation: Rc::clone(&lyrics.set_presentation),
        set_lyrics_insets: Rc::clone(&lyrics.set_insets),
        chrome,
    });
    follow_the_stage(&layout, &video, &lyrics.set_caption_layout, &cover, &card);

    {
        let layout = Rc::clone(&layout);
        let set_active = Rc::clone(&lyrics.set_active);
        let ui = Rc::clone(ui);
        let syncing = Rc::clone(&syncing);
        lyrics_toggle.connect_toggled(move |button| {
            let active = button.is_active();
            set_active(active);
            layout.apply();
            if !syncing.get() {
                ui.core.config.borrow_mut().np_show_lyrics = active;
                ui.core.save_config();
            }
        });
    }
    wire_side_toggle(
        ui,
        &layout,
        &queue_toggle,
        &comments_toggle,
        Rc::clone(&queue.set_active),
        remember_queue,
        &syncing,
    );
    wire_side_toggle(
        ui,
        &layout,
        &comments_toggle,
        &queue_toggle,
        Rc::clone(&comments.set_active),
        remember_comments,
        &syncing,
    );
    {
        let layout = Rc::clone(&layout);
        let ui = Rc::clone(ui);
        video.lyrics_style.connect_active_name_notify(move |group| {
            let style = LyricsStyle::from_id(group.active_name().as_deref().unwrap_or_default());
            ui.core.config.borrow_mut().np_video_lyrics = style.id().to_string();
            ui.core.save_config();
            layout.apply();
        });
    }
    restore_chosen_panels(ui, &layout);
    let dock = DockFit {
        transport: transport.container.clone(),
        skips: transport.skips.to_vec(),
        volume: volume.container.clone(),
        skip_width: Cell::new(0),
        volume_width: Cell::new(0),
    };
    install_now_playing_width_adaptation(ui, &stage, &layout, dock, &syncing);

    {
        let layout = Rc::clone(&layout);
        layout.apply_sides(ui.core.config.borrow().np_swap_sides);
        let ui = Rc::clone(ui);
        video.lyrics_right.connect_active_notify(move |switch| {
            let swapped = switch.is_active();
            if ui.core.config.borrow().np_swap_sides == swapped {
                return;
            }
            ui.core.config.borrow_mut().np_swap_sides = swapped;
            ui.core.save_config();
            layout.apply_sides(swapped);
        });
    }
    install_fullscreen(ui, &overlay, &fullscreen, &video, &cover);

    let update = build_updater(ui, &cover, &backdrop, &transport.love, &current_rel);
    update();

    transport.sync_initial(ui);
    update_up_next_label(ui, &queue_label);

    wire_events(ui, &overlay, &transport, &current_rel, &queue_label, update);

    if crate::config::demo_mode() {
        if let Ok(which) = std::env::var("FLACCY_DEMO_NP_PANELS") {
            let all = which == "both" || which == "1";
            if all || which.contains("lyrics") {
                lyrics_toggle.set_active(true);
            }
            if all || which.contains("queue") {
                queue_toggle.set_active(true);
            }
            if which.contains("comments") {
                comments_toggle.set_active(true);
            }
        }
    }

    syncing.set(false);

    park_video_off_screen(ui, &overlay);

    let page = adw::NavigationPage::builder()
        .title("Now Playing")
        .tag("now-playing")
        .child(&overlay)
        .build();
    ui.shell.push(&page);
}

/// Writes whether a side panel is open into the config.
type Remember = fn(&mut crate::config::Config, bool);

/// Up Next and Comments share the side of the stage the lyrics leave free,
/// so opening one closes the other.
fn wire_side_toggle(
    ui: &Rc<Ui>,
    layout: &Rc<Layout>,
    toggle: &gtk::ToggleButton,
    other: &gtk::ToggleButton,
    set_active: Rc<dyn Fn(bool)>,
    remember: Remember,
    syncing: &Rc<Cell<bool>>,
) {
    let layout = Rc::clone(layout);
    let ui = Rc::clone(ui);
    let other = other.clone();
    let syncing = Rc::clone(syncing);
    toggle.connect_toggled(move |button| {
        let active = button.is_active();
        if active && other.is_active() {
            other.set_active(false);
        }
        set_active(active);
        layout.apply();
        if !syncing.get() {
            remember(&mut ui.core.config.borrow_mut(), active);
            ui.core.save_config();
        }
    });
}

fn remember_queue(config: &mut crate::config::Config, shown: bool) {
    config.np_show_queue = shown;
    if shown {
        config.np_show_comments = false;
    }
}

fn remember_comments(config: &mut crate::config::Config, shown: bool) {
    config.np_show_comments = shown;
    if shown {
        config.np_show_queue = false;
    }
}

/// Where the lyrics and the side panel go on the stage, and which of Up Next
/// and Comments the side panel shows.
struct Layout {
    ui: Rc<Ui>,
    stage: VideoStage,
    toolbar: adw::ToolbarView,
    side: gtk::Stack,
    lyrics_toggle: gtk::ToggleButton,
    queue_toggle: gtk::ToggleButton,
    comments_toggle: gtk::ToggleButton,
    set_presentation: Rc<dyn Fn(Presentation)>,
    set_lyrics_insets: Rc<dyn Fn(i32, i32)>,
    chrome: Rc<StageChrome>,
}

impl Layout {
    /// Brings the stage in line with the toggles.
    fn apply(&self) {
        let lyrics = self.lyrics_toggle.is_active();
        let queue = self.queue_toggle.is_active();
        let comments = self.comments_toggle.is_active();
        let style = LyricsStyle::from_id(&self.ui.core.config.borrow().np_video_lyrics);
        if comments {
            self.side.set_visible_child_name("comments");
        } else if queue {
            self.side.set_visible_child_name("queue");
        }
        self.stage.set_lyrics(lyrics.then_some(style));
        self.stage.set_queue(queue || comments);
    }

    /// Puts the lyrics on the left, or on the right with the side panel on
    /// the left.
    fn apply_sides(&self, swapped: bool) {
        self.stage
            .set_lyrics_side(if swapped { Side::Right } else { Side::Left });
    }
}

/// Keeps the stage and everything on it in step with the video: the video
/// once its first frame of this song is up (at its shape, bars cropped away),
/// the cover otherwise, which also brings the dark room, the resting chrome
/// and the title card's place with it; how far the header and dock reach; and
/// whether the lyrics are a column or captions wherever the stage put them.
fn follow_the_stage(
    layout: &Rc<Layout>,
    video: &VideoView,
    set_caption_layout: &Rc<dyn Fn(f64, f64)>,
    cover: &gtk::Picture,
    card: &TitleCard,
) {
    let stage = layout.stage.clone();
    let revealed = Rc::new(Cell::new(false));
    let show_picture: Rc<dyn Fn()> = {
        let surface = video.surface.clone();
        let card = card.clone();
        let layout = Rc::downgrade(layout);
        Rc::new(move || {
            let Some(layout) = layout.upgrade() else { return };
            let lens = &layout.ui.core.music_video;
            match lens.stage_state() {
                StageState::Playing => revealed.set(true),
                StageState::Buffering(_) => {}
                StageState::Idle | StageState::Opening | StageState::Failed(_) => {
                    revealed.set(false)
                }
            }
            let has_picture = lens.state().matched().is_some()
                && !lens.exhausted()
                && revealed.get()
                && surface.has_frame();
            let aspect = if has_picture {
                surface.aspect().unwrap_or(DEFAULT_ASPECT)
            } else {
                1.0
            };
            layout.stage.set_picture(!has_picture, aspect);
            card.set_cover(!has_picture);
            layout.chrome.set_stage(has_picture);
        })
    };
    show_picture();
    {
        let show_picture = Rc::clone(&show_picture);
        video.surface.connect_shape(move || show_picture());
    }
    {
        let show_picture = Rc::clone(&show_picture);
        layout
            .ui
            .core
            .hub
            .subscribe_widget(&stage, move |_, event| {
                if matches!(event, AppEvent::MusicVideoChanged | AppEvent::TrackChanged(_)) {
                    show_picture();
                }
            });
    }

    let insets: Rc<dyn Fn()> = {
        let layout = Rc::downgrade(layout);
        Rc::new(move || {
            let Some(layout) = layout.upgrade() else { return };
            let (top, bottom) = (
                layout.toolbar.top_bar_height() as f64,
                layout.toolbar.bottom_bar_height() as f64,
            );
            layout.stage.set_insets(top, bottom);
            if layout.chrome.is_shown() {
                layout.stage.set_chrome_insets(top, bottom);
            }
        })
    };
    insets();
    {
        let insets = Rc::clone(&insets);
        layout
            .toolbar
            .connect_top_bar_height_notify(move |_| insets());
    }
    layout
        .toolbar
        .connect_bottom_bar_height_notify(move |_| insets());

    let weak = Rc::downgrade(layout);
    let picture = video.picture.clone();
    let cover = cover.clone();
    let set_caption_layout = Rc::clone(set_caption_layout);
    stage.connect_arranged(move |arrangement: &Arrangement| {
        let Some(layout) = weak.upgrade() else { return };
        let captions = arrangement.placement() == Some(Placement::Captions);
        (layout.set_presentation)(if captions {
            Presentation::Captions
        } else {
            Presentation::Column
        });
        if let Some(band) = arrangement.captions {
            set_caption_layout(band.scale, band.margin);
        }
        if let Some((_, rect)) = arrangement.lyrics {
            let top = layout.toolbar.top_bar_height() as f64 - rect.y;
            let foot = layout.stage.height() as f64 - layout.toolbar.bottom_bar_height() as f64;
            let bottom = rect.bottom() - foot;
            (layout.set_lyrics_insets)(top.max(0.0) as i32, bottom.max(0.0) as i32);
        }
        for widget in [picture.upcast_ref::<gtk::Widget>(), cover.upcast_ref()] {
            if arrangement.floating {
                widget.add_css_class("floating");
            } else {
                widget.remove_css_class("floating");
            }
        }
    });
}

/// The title card: artist, title (with the New mix chip), album and the
/// file's quality, and when the audio was last exported. Over a video it is
/// the music-television card in a corner, shown as a song starts and with
/// the chrome; under the cover it is the page's title, centred and always up.
#[derive(Clone)]
struct TitleCard {
    widget: gtk::Revealer,
    body: gtk::Box,
    lines: Vec<gtk::Label>,
    title_row: gtk::Box,
}

impl TitleCard {
    /// Sets the card under the cover, centred, or over the video in a corner.
    fn set_cover(&self, cover: bool) {
        if cover == self.body.has_css_class("under-cover") {
            return;
        }
        if cover {
            self.body.add_css_class("under-cover");
        } else {
            self.body.remove_css_class("under-cover");
        }
        let (xalign, justify, align) = if cover {
            (0.5, gtk::Justification::Center, gtk::Align::Center)
        } else {
            (0.0, gtk::Justification::Left, gtk::Align::Start)
        };
        for label in &self.lines {
            label.set_xalign(xalign);
            label.set_justify(justify);
        }
        self.title_row.set_halign(align);
    }
}

fn title_card(ui: &Rc<Ui>) -> TitleCard {
    let artist = gtk::Label::builder()
        .xalign(0.0)
        .ellipsize(pango::EllipsizeMode::End)
        .build();
    artist.add_css_class("np-card-artist");
    let title = gtk::Label::builder()
        .xalign(0.0)
        .wrap(true)
        .wrap_mode(pango::WrapMode::WordChar)
        .ellipsize(pango::EllipsizeMode::End)
        .lines(2)
        .max_width_chars(28)
        .build();
    title.add_css_class("np-card-title");
    let meta = gtk::Label::builder()
        .xalign(0.0)
        .ellipsize(pango::EllipsizeMode::End)
        .build();
    meta.add_css_class("np-card-meta");
    attach_label_nav(ui, &artist, "Go to Artist", |ui| {
        if let Some(track) = ui.core.player.current_track() {
            crate::ui::goto_artist(ui, &track.artist);
        }
    });
    attach_label_nav(ui, &meta, "Go to Album", |ui| {
        if let Some(track) = ui.core.player.current_track() {
            crate::ui::goto_album_of_track(ui, &track.rel_path);
        }
    });
    let mix = VersionBadge::new();
    mix.chip.set_valign(gtk::Align::Center);
    let exported = mix.exported.clone();
    let title_row = gtk::Box::new(gtk::Orientation::Horizontal, 10);
    title_row.append(&title);
    title_row.append(&mix.chip);
    let body = gtk::Box::new(gtk::Orientation::Vertical, 2);
    body.add_css_class("np-card");
    body.append(&artist);
    body.append(&title_row);
    body.append(&meta);
    body.append(&mix.exported);
    let widget = gtk::Revealer::builder()
        .transition_type(gtk::RevealerTransitionType::Crossfade)
        .transition_duration(360)
        .reveal_child(true)
        .child(&body)
        .build();

    let fill = {
        let ui = Rc::clone(ui);
        let artist = artist.clone();
        let title = title.clone();
        let meta = meta.clone();
        move || {
            let Some(track) = ui.core.player.current_track() else {
                artist.set_label("");
                title.set_label("Not Playing");
                meta.set_label("");
                mix.hide();
                return;
            };
            artist.set_label(&track.artist);
            title.set_label(&track.title);
            let line = match track.quality_badge() {
                Some(badge) if !track.album.is_empty() => format!("{} · {badge}", track.album),
                Some(badge) => badge,
                None => track.album.clone(),
            };
            meta.set_label(&line);
            let fresh = ui
                .core
                .library
                .borrow()
                .track_by_rel_path(&track.rel_path)
                .cloned();
            mix.show(fresh.as_ref().unwrap_or(&track));
        }
    };
    fill();
    ui.core.hub.subscribe_widget(&widget, move |_, event| {
        if matches!(event, AppEvent::TrackChanged(_) | AppEvent::LibraryReloaded) {
            fill();
        }
    });
    let card = TitleCard {
        widget,
        body,
        lines: vec![artist, title, meta, exported],
        title_row,
    };
    card.set_cover(true);
    card
}

/// The header, the dock and the pointer over a playing video: shown while the
/// pointer moves, a key is pressed, the video pauses or a menu is open, and
/// out of the way once the pointer rests, the way a video player behaves.
/// Over the cover they never hide.
struct StageChrome {
    ui: Rc<Ui>,
    toolbar: adw::ToolbarView,
    stage: VideoStage,
    root: RefCell<Option<glib::WeakRef<gtk::Overlay>>>,
    /// The header, the dock and the side panel: the chrome stays while the
    /// pointer is over any of them.
    hovers: [gtk::EventControllerMotion; 3],
    tools: gtk::MenuButton,
    card: gtk::Revealer,
    active: Cell<bool>,
    shown: Cell<bool>,
    holding_card: Cell<bool>,
    linger: RefCell<Option<glib::SourceId>>,
    hold: RefCell<Option<glib::SourceId>>,
    pointer: Cell<(f64, f64)>,
}

impl StageChrome {
    fn new(
        ui: &Rc<Ui>,
        toolbar: &adw::ToolbarView,
        held: [&gtk::Widget; 3],
        stage: &VideoStage,
        card: &TitleCard,
        video: &VideoView,
    ) -> Rc<Self> {
        let hovers = held.map(|widget| {
            let hover = gtk::EventControllerMotion::new();
            widget.add_controller(hover.clone());
            hover
        });
        Rc::new(Self {
            ui: Rc::clone(ui),
            toolbar: toolbar.clone(),
            stage: stage.clone(),
            root: RefCell::new(None),
            hovers,
            tools: video.tools.clone(),
            card: card.widget.clone(),
            active: Cell::new(false),
            shown: Cell::new(true),
            holding_card: Cell::new(false),
            linger: RefCell::new(None),
            hold: RefCell::new(None),
            pointer: Cell::new((f64::NAN, f64::NAN)),
        })
    }

    /// Listens on the page for the pointer and keys, and to the player for
    /// pauses and new songs.
    fn install(self: &Rc<Self>, root: &gtk::Overlay) {
        *self.root.borrow_mut() = Some(root.downgrade());
        let motion = gtk::EventControllerMotion::new();
        {
            let chrome = Rc::downgrade(self);
            motion.connect_motion(move |_, x, y| {
                let Some(chrome) = chrome.upgrade() else { return };
                if chrome.pointer.replace((x, y)) != (x, y) {
                    chrome.wake();
                }
            });
        }
        root.add_controller(motion);
        let keys = gtk::EventControllerKey::new();
        keys.set_propagation_phase(gtk::PropagationPhase::Capture);
        {
            let chrome = Rc::downgrade(self);
            keys.connect_key_pressed(move |_, _, _, _| {
                if let Some(chrome) = chrome.upgrade() {
                    chrome.wake();
                }
                glib::Propagation::Proceed
            });
        }
        root.add_controller(keys);
        {
            let chrome = Rc::downgrade(self);
            self.tools.connect_active_notify(move |_| {
                if let Some(chrome) = chrome.upgrade() {
                    chrome.wake();
                }
            });
        }
        let chrome = Rc::downgrade(self);
        self.ui.core.hub.subscribe_widget(root, move |_, event| {
            let Some(chrome) = chrome.upgrade() else { return };
            match event {
                AppEvent::TrackChanged(_) => chrome.hold_card(),
                AppEvent::PlayingChanged(_) | AppEvent::MusicVideoChanged => chrome.reconsider(),
                _ => {}
            }
        });
    }

    /// Turns the page into the dark room a video plays in, with chrome that
    /// rests, or back into the cover's own light.
    fn set_stage(self: &Rc<Self>, active: bool) {
        if self.active.replace(active) == active {
            return;
        }
        if let Some(root) = self.root.borrow().as_ref().and_then(|root| root.upgrade()) {
            if active {
                root.add_css_class("np-stage");
            } else {
                root.remove_css_class("np-stage");
            }
        }
        if active {
            self.hold_card();
        }
        self.wake();
    }

    fn wake(self: &Rc<Self>) {
        self.reveal(true);
        if let Some(source) = self.linger.borrow_mut().take() {
            source.remove();
        }
        if !self.active.get() {
            return;
        }
        let chrome = Rc::downgrade(self);
        let source = glib::timeout_add_local_once(CHROME_LINGER, move || {
            let Some(chrome) = chrome.upgrade() else { return };
            chrome.linger.borrow_mut().take();
            if chrome.may_rest() {
                chrome.reveal(false);
            }
        });
        *self.linger.borrow_mut() = Some(source);
    }

    /// After a pause, a new song or a change in the video: the chrome comes
    /// back when the music stops or the picture goes, and a playing picture
    /// gets its rest timer if none is running. A buffering blip never brings
    /// the chrome back by itself.
    fn reconsider(self: &Rc<Self>) {
        if !self.active.get() {
            return;
        }
        let picture = self.ui.core.music_video.state().matched().is_some();
        let stopped = !self.ui.core.player.is_playing() || !picture;
        let untimed = self.shown.get() && self.linger.borrow().is_none();
        if stopped || untimed {
            self.wake();
        }
    }

    /// The chrome steps aside only over a video that is playing, with the
    /// pointer off the bars and the side panel and no menu open.
    fn may_rest(&self) -> bool {
        self.active.get()
            && video_view::is_playing_video(&self.ui)
            && !self.hovers.iter().any(|hover| hover.contains_pointer())
            && !self.tools.is_active()
    }

    fn is_shown(&self) -> bool {
        self.shown.get()
    }

    fn reveal(&self, shown: bool) {
        let shown = shown || !self.active.get();
        if self.shown.replace(shown) != shown {
            self.toolbar.set_reveal_top_bars(shown);
            self.toolbar.set_reveal_bottom_bars(shown);
            if let Some(root) = self.root.borrow().as_ref().and_then(|root| root.upgrade()) {
                if shown {
                    root.remove_css_class("np-chrome-hidden");
                } else {
                    root.add_css_class("np-chrome-hidden");
                }
            }
            if shown {
                self.stage.set_cursor(None);
            } else {
                self.stage.set_cursor_from_name(Some("none"));
            }
        }
        self.show_card();
    }

    /// Keeps the title card up for a while as a song starts, chrome or not.
    fn hold_card(self: &Rc<Self>) {
        if let Some(source) = self.hold.borrow_mut().take() {
            source.remove();
        }
        self.holding_card.set(true);
        let chrome = Rc::downgrade(self);
        let source = glib::timeout_add_local_once(CARD_HOLD, move || {
            let Some(chrome) = chrome.upgrade() else { return };
            chrome.hold.borrow_mut().take();
            chrome.holding_card.set(false);
            chrome.show_card();
        });
        *self.hold.borrow_mut() = Some(source);
        self.show_card();
    }

    /// Under the cover the card is the page's title and always shows; over a
    /// video it comes and goes with the chrome.
    fn show_card(&self) {
        let wanted = !self.active.get() || self.shown.get() || self.holding_card.get();
        self.card.set_reveal_child(wanted);
    }
}

/// Full screen for the whole window from the header button, F11 or a double
/// click on the picture; Escape leaves it, and so does leaving Now Playing.
fn install_fullscreen(
    ui: &Rc<Ui>,
    root: &gtk::Overlay,
    button: &gtk::Button,
    video: &VideoView,
    cover: &gtk::Picture,
) {
    let made_full = Rc::new(Cell::new(false));
    let toggle: Rc<dyn Fn()> = {
        let window = ui.window.clone();
        let made_full = Rc::clone(&made_full);
        Rc::new(move || {
            if window.is_fullscreen() {
                window.unfullscreen();
            } else {
                made_full.set(true);
                window.fullscreen();
            }
        })
    };
    {
        let toggle = Rc::clone(&toggle);
        button.connect_clicked(move |_| toggle());
    }
    for surface in [video.picture.clone(), cover.clone().upcast()] {
        let click = gtk::GestureClick::new();
        let toggle = Rc::clone(&toggle);
        click.connect_pressed(move |gesture, presses, _, _| {
            if presses == 2 {
                gesture.set_state(gtk::EventSequenceState::Claimed);
                toggle();
            }
        });
        surface.add_controller(click);
    }
    let keys = gtk::EventControllerKey::new();
    {
        let window = ui.window.clone();
        let toggle = Rc::clone(&toggle);
        keys.connect_key_pressed(move |_, key, _, _| match key {
            gdk::Key::F11 => {
                toggle();
                glib::Propagation::Stop
            }
            gdk::Key::Escape if window.is_fullscreen() => {
                window.unfullscreen();
                glib::Propagation::Stop
            }
            _ => glib::Propagation::Proceed,
        });
    }
    root.add_controller(keys);

    let show_state = {
        let button = button.downgrade();
        move |window: &adw::ApplicationWindow| {
            let Some(button) = button.upgrade() else { return };
            let full = window.is_fullscreen();
            button.set_icon_name(if full {
                "view-restore-symbolic"
            } else {
                "view-fullscreen-symbolic"
            });
            button.set_tooltip_text(Some(if full {
                "Leave Full Screen (Esc)"
            } else {
                "Full Screen (F11)"
            }));
        }
    };
    show_state(&ui.window);
    let handler = ui.window.connect_fullscreened_notify(show_state);
    {
        let window = ui.window.clone();
        root.connect_unmap(move |_| {
            if made_full.replace(false) && window.is_fullscreen() {
                window.unfullscreen();
            }
        });
    }
    let window = ui.window.clone();
    let handler = RefCell::new(Some(handler));
    root.connect_destroy(move |_| {
        if let Some(handler) = handler.borrow_mut().take() {
            window.disconnect(handler);
        }
    });
}

/// Decides which optional dock controls fit a width, from what they actually
/// measure — the interface zoom changes every one of them. A widget measures
/// zero while hidden, so each is remembered from the last time it was shown.
struct DockFit {
    transport: gtk::Box,
    skips: Vec<gtk::Button>,
    volume: gtk::Box,
    skip_width: Cell<i32>,
    volume_width: Cell<i32>,
}

impl DockFit {
    /// Shows the skip buttons, then the volume cluster, only while they fit.
    /// Whatever is showing always fits the width it was decided for, so a
    /// window being narrowed is never held open by a control that should
    /// already have folded away.
    fn apply(&self, width: i32) {
        let horizontal = gtk::Orientation::Horizontal;
        let skips_shown = self.skips.iter().all(|skip| skip.is_visible());
        if skips_shown {
            let spacing = self.transport.spacing();
            let skips = self
                .skips
                .iter()
                .map(|skip| skip.measure(horizontal, -1).0 + spacing)
                .sum();
            self.skip_width.set(skips);
        }
        if self.volume.is_visible() {
            self.volume_width.set(self.volume.measure(horizontal, -1).0);
        }
        let shown = if skips_shown { self.skip_width.get() } else { 0 };
        let core = self.transport.measure(horizontal, -1).0 - shown;
        let with_skips = core + self.skip_width.get() + DOCK_CHROME;
        let show_skips = width >= with_skips;
        let show_volume = show_skips && width >= with_skips + self.volume_width.get();
        for skip in &self.skips {
            skip.set_visible(show_skips);
        }
        self.volume.set_visible(show_volume);
    }
}

/// When Now Playing is squeezed, fold the side panel away while the lyrics
/// are open, so the picture is never crushed between two columns on a narrow
/// window, and fold away the volume cluster, then the skip buttons, so the
/// transport buttons keep their centerline.
fn install_now_playing_width_adaptation(
    ui: &Rc<Ui>,
    content: &impl IsA<gtk::Widget>,
    layout: &Rc<Layout>,
    dock: DockFit,
    syncing: &Rc<Cell<bool>>,
) {
    let ui = Rc::clone(ui);
    let layout = Rc::clone(layout);
    let dock = Rc::new(dock);
    let syncing = Rc::clone(syncing);
    crate::ui::resize::watch_width(content, move |width, previous| {
        let open_side = [&layout.queue_toggle, &layout.comments_toggle]
            .into_iter()
            .find(|toggle| toggle.is_active());
        if width < ONE_PANEL_WIDTH && layout.lyrics_toggle.is_active() {
            if let Some(side) = open_side {
                syncing.set(true);
                side.set_active(false);
                syncing.set(false);
            }
        } else if width >= ONE_PANEL_WIDTH && previous > 0 && previous < ONE_PANEL_WIDTH {
            syncing.set(true);
            restore_chosen_panels(&ui, &layout);
            syncing.set(false);
        }
        dock.apply(width);
    });
}

/// Opens the panels the person chose, at start and when widening again;
/// otherwise a panel folded away at phone width never returns.
fn restore_chosen_panels(ui: &Rc<Ui>, layout: &Layout) {
    let (lyrics, queue, comments) = {
        let config = ui.core.config.borrow();
        (
            config.np_show_lyrics,
            config.np_show_queue,
            config.np_show_comments,
        )
    };
    layout.lyrics_toggle.set_active(lyrics);
    if queue {
        layout.queue_toggle.set_active(true);
    } else if comments && layout.comments_toggle.is_visible() {
        layout.comments_toggle.set_active(true);
    }
}

/// Parks the video pipeline whenever Now Playing isn't on screen — another
/// page, or a window the compositor has minimised or hidden — so nothing is
/// decoded that nobody sees, and resumes it on the way back in.
fn park_video_off_screen(ui: &Rc<Ui>, host: &gtk::Overlay) {
    let update: Rc<dyn Fn()> = {
        let ui = Rc::clone(ui);
        let host = host.downgrade();
        Rc::new(move || {
            let Some(host) = host.upgrade() else {
                return;
            };
            let showing = host.is_mapped()
                && crate::musicvideo::available()
                && !ui.window.is_suspended();
            crate::musicvideo::set_visible(&ui.core, showing);
        })
    };
    {
        let update = Rc::clone(&update);
        host.connect_map(move |_| update());
    }
    {
        let ui = Rc::clone(ui);
        host.connect_unmap(move |_| crate::musicvideo::set_visible(&ui.core, false));
    }
    update();
    ui.window.connect_suspended_notify(move |_| update());
}

/// A pill toggle carrying an icon + label, returned with its label so a live
/// count can be appended.
fn toggle_button(icon: &str, text: &str) -> (gtk::ToggleButton, gtk::Label) {
    let image = gtk::Image::from_icon_name(icon);
    let label = gtk::Label::new(Some(text));
    let content = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    content.append(&image);
    content.append(&label);
    let button = gtk::ToggleButton::builder().child(&content).build();
    button.add_css_class("np-toggle");
    button.set_tooltip_text(Some(text));
    (button, label)
}

/// The persistent transport row: shuffle, back 15 s, prev, play/pause, next,
/// forward 15 s, repeat, love.
struct TransportControls {
    container: gtk::Box,
    play: gtk::Button,
    shuffle: gtk::ToggleButton,
    repeat: gtk::Button,
    love: gtk::Button,
    skips: [gtk::Button; 2],
}

impl TransportControls {
    fn new(ui: &Rc<Ui>) -> Self {
        let shuffle = gtk::ToggleButton::builder()
            .icon_name("media-playlist-shuffle-symbolic")
            .tooltip_text("Shuffle")
            .build();
        shuffle.add_css_class("flat");
        {
            let ui = Rc::clone(ui);
            shuffle.connect_clicked(move |button| {
                if button.is_active() != ui.core.player.shuffle_enabled() {
                    ui.core.player.toggle_shuffle();
                }
            });
        }
        let back = skip_button(
            ui,
            "flaccy-skip-back-15-symbolic",
            -SKIP_SECONDS,
            "Back 15 seconds",
            "Shift+←",
        );
        let previous = icon_button("media-skip-backward-symbolic", "Previous");
        {
            let ui = Rc::clone(ui);
            previous.connect_clicked(move |_| ui.core.previous());
        }
        let play = gtk::Button::from_icon_name("media-playback-start-symbolic");
        play.add_css_class("suggested-action");
        play.add_css_class("circular");
        play.add_css_class("np-play");
        play.set_tooltip_text(Some("Play/Pause"));
        {
            let ui = Rc::clone(ui);
            play.connect_clicked(move |_| ui.core.toggle_play_pause());
        }
        let next = icon_button("media-skip-forward-symbolic", "Next");
        {
            let ui = Rc::clone(ui);
            next.connect_clicked(move |_| ui.core.next());
        }
        let forward = skip_button(
            ui,
            "flaccy-skip-forward-15-symbolic",
            SKIP_SECONDS,
            "Forward 15 seconds",
            "Shift+→",
        );
        let repeat = gtk::Button::from_icon_name("media-playlist-repeat-symbolic");
        repeat.add_css_class("flat");
        repeat.set_opacity(0.5);
        repeat.set_tooltip_text(Some("Repeat"));
        {
            let ui = Rc::clone(ui);
            repeat.connect_clicked(move |_| ui.core.player.cycle_repeat());
        }
        let love = gtk::Button::from_icon_name("emote-love-symbolic");
        love.add_css_class("flat");
        love.set_tooltip_text(Some("Love on Last.fm"));

        let container = gtk::Box::builder()
            .orientation(gtk::Orientation::Horizontal)
            .spacing(16)
            .halign(gtk::Align::Center)
            .build();
        container.append(&shuffle);
        container.append(&back);
        container.append(&previous);
        container.append(&play);
        container.append(&next);
        container.append(&forward);
        container.append(&repeat);
        container.append(&love);
        Self {
            container,
            play,
            shuffle,
            repeat,
            love,
            skips: [back, forward],
        }
    }

    fn sync_initial(&self, ui: &Rc<Ui>) {
        self.play.set_icon_name(if ui.core.player.is_playing() {
            "media-playback-pause-symbolic"
        } else {
            "media-playback-start-symbolic"
        });
        self.shuffle.set_active(ui.core.player.shuffle_enabled());
        apply_repeat(&self.repeat, ui.core.player.repeat_mode());
    }
}

fn icon_button(icon: &str, tooltip: &str) -> gtk::Button {
    let button = gtk::Button::from_icon_name(icon);
    button.add_css_class("flat");
    button.add_css_class("np-skip");
    button.set_tooltip_text(Some(tooltip));
    button
}

fn skip_button(ui: &Rc<Ui>, icon: &str, seconds: f64, name: &str, shortcut: &str) -> gtk::Button {
    let button = gtk::Button::from_icon_name(icon);
    button.add_css_class("flat");
    button.add_css_class("np-skip-seconds");
    button.set_tooltip_text(Some(&format!("{name} ({shortcut})")));
    button.update_property(&[gtk::accessible::Property::Label(name)]);
    let ui = Rc::clone(ui);
    button.connect_clicked(move |_| ui.core.skip_by(seconds));
    button
}

/// Refreshes the "Up Next" toggle label with the live up-next count.
fn update_up_next_label(ui: &Rc<Ui>, label: &gtk::Label) {
    let count = ui.core.player.queue_summary().up_next();
    if count > 0 {
        label.set_label(&format!("Up Next · {count}"));
    } else {
        label.set_label("Up Next");
    }
}

/// What Now Playing says about the playing file's versions: the New mix chip
/// beside the title, and under it when the audio was last exported.
#[derive(Clone)]
struct VersionBadge {
    chip: gtk::Label,
    exported: gtk::Label,
}

impl VersionBadge {
    fn new() -> Self {
        let exported = gtk::Label::builder()
            .xalign(0.5)
            .visible(false)
            .build();
        exported.add_css_class("np-meta");
        exported.add_css_class("dim");
        exported.add_css_class("caption");
        Self {
            chip: crate::ui::controls::new_mix_chip(),
            exported,
        }
    }

    /// Shows the chip while the re-export is recent, and the export time once
    /// the song has been re-exported at all.
    fn show(&self, track: &Track) {
        self.chip.set_visible(crate::ui::controls::shows_new_mix(track));
        match exported_text(track) {
            Some(text) => {
                self.exported.set_label(&text);
                self.exported.set_visible(true);
            }
            None => self.exported.set_visible(false),
        }
    }

    fn hide(&self) {
        self.chip.set_visible(false);
        self.exported.set_visible(false);
    }
}

/// `Exported 25 Oct 2026 at 14:02` in local time, for a song whose audio has
/// been replaced at least once.
fn exported_text(track: &Track) -> Option<String> {
    if track.revision <= 1 {
        return None;
    }
    let modified = chrono::DateTime::<chrono::Utc>::from_timestamp_millis(track.file_modified_ms?)?
        .with_timezone(&chrono::Local);
    Some(copy::fill(
        copy::EXPORTED_AT,
        &[
            &modified.format("%-d %b %Y").to_string(),
            &modified.format("%H:%M").to_string(),
        ],
    ))
}

type Updater = Rc<dyn Fn()>;

/// Repaints the cover (sharp, plus the pre-blurred backdrop) and the love
/// button for the current track; reused on open and on every TrackChanged.
fn build_updater(
    ui: &Rc<Ui>,
    art: &gtk::Picture,
    backdrop: &gtk::Picture,
    love: &gtk::Button,
    current_rel: &Rc<RefCell<Option<String>>>,
) -> Updater {
    let ui = Rc::clone(ui);
    let art = art.clone();
    let backdrop = backdrop.clone();
    let love = love.clone();
    let current_rel = Rc::clone(current_rel);
    Rc::new(move || {
        let Some(track) = ui.core.player.current_track() else {
            love.set_sensitive(false);
            *current_rel.borrow_mut() = None;
            return;
        };
        love.set_sensitive(true);
        set_love_appearance(&love, track.loved);
        *current_rel.borrow_mut() = Some(track.rel_path.clone());

        let seed = format!("{}|{}", track.album, track.artist);
        let placeholder = ui.core.artwork.placeholder(&seed);
        art.set_paintable(Some(&placeholder));
        backdrop.set_paintable(Some(&placeholder));
        let art_weak = art.downgrade();
        ui.core
            .artwork
            .request(&track.album, &track.artist, COVER_SIZE, move |texture, _| {
                if let (Some(texture), Some(art)) = (texture, art_weak.upgrade()) {
                    art.set_paintable(Some(texture));
                }
            });
        let backdrop_weak = backdrop.downgrade();
        ui.core
            .artwork
            .request_backdrop(&track.album, &track.artist, move |texture| {
                if let (Some(texture), Some(backdrop)) = (texture, backdrop_weak.upgrade()) {
                    backdrop.set_paintable(Some(texture));
                }
            });
    })
}

fn wire_events(
    ui: &Rc<Ui>,
    host: &gtk::Overlay,
    transport: &TransportControls,
    current_rel: &Rc<RefCell<Option<String>>>,
    queue_label: &gtk::Label,
    update: Updater,
) {
    let hub = Rc::clone(&ui.core.hub);
    let ui = Rc::clone(ui);
    let play = transport.play.clone();
    let shuffle = transport.shuffle.clone();
    let repeat = transport.repeat.clone();
    let love = transport.love.clone();
    let current_rel = Rc::clone(current_rel);
    let queue_label = queue_label.clone();
    hub.subscribe_widget(host, move |_, event| match event {
        AppEvent::TrackChanged(_) => {
            update();
            update_up_next_label(&ui, &queue_label);
        }
        AppEvent::QueueChanged => update_up_next_label(&ui, &queue_label),
        AppEvent::AlbumArtworkChanged { title, artist } => {
            let playing_this = ui
                .core
                .player
                .current_track()
                .is_some_and(|track| &track.album == title && &track.artist == artist);
            if playing_this {
                update();
            }
        }
        AppEvent::PlayingChanged(playing) => {
            play.set_icon_name(if *playing {
                "media-playback-pause-symbolic"
            } else {
                "media-playback-start-symbolic"
            });
        }
        AppEvent::ShuffleChanged(enabled) => shuffle.set_active(*enabled),
        AppEvent::RepeatChanged(mode) => apply_repeat(&repeat, *mode),
        AppEvent::LovedChanged { rel_path, loved } => {
            if current_rel.borrow().as_deref() == Some(rel_path.as_str()) {
                set_love_appearance(&love, *loved);
            }
        }
        _ => {}
    });
}
