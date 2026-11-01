use crate::events::AppEvent;
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

/// Full-window "focus" player pushed onto the outer nav (ui.shell). A blurred,
/// accent-washed cover fills the page; the hero artwork sits centered with
/// Lyrics and Up Next columns that slide in on either side — independently
/// toggled, so any combination of the three can be shown at once, and a header
/// swap button flips which side each column lives on (persisted) — over a
/// single persistent transport dock with a volume cluster. The artist and
/// album labels navigate to their library pages. The Video toggle turns the
/// page into a stage: the music video as large as the window allows, the glow
/// it casts around it, and the lyrics and Up Next laid beside, under or over
/// the picture, with the header and dock floating over it and stepping out of
/// the way while the pointer rests.
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

    let (art_page, art, title, artist, meta, quality, mix) = build_art_lens();
    artist.set_halign(gtk::Align::Center);
    meta.set_halign(gtk::Align::Center);
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
    lyrics.widget.add_css_class("np-side");
    lyrics.widget.set_hexpand(true);
    // Soft floor so a side column can shrink under a phone-width window
    // instead of locking the whole Now Playing page open.
    lyrics.widget.set_size_request(160, -1);
    let lyrics_reveal = gtk::Revealer::builder()
        .transition_type(gtk::RevealerTransitionType::SlideRight)
        .transition_duration(260)
        .hexpand(false)
        .child(&lyrics.widget)
        .build();

    let queue = queue_panel::build(ui, QueueOptions::in_view());
    queue.widget.add_css_class("np-view");
    queue.widget.add_css_class("np-side");
    queue.widget.set_hexpand(true);
    queue.widget.set_size_request(160, -1);
    let queue_reveal = gtk::Revealer::builder()
        .transition_type(gtk::RevealerTransitionType::SlideLeft)
        .transition_duration(260)
        .hexpand(false)
        .child(&queue.widget)
        .build();

    // Equal thirds when all shown: a horizontal size group equalizes the three
    // columns' widths, and each visible column hexpands to split the row evenly.
    // A collapsed side reveals nothing and (via its toggle) drops hexpand, so
    // the visible columns always share the row equally — art alone, art+one
    // half/half, or all three in thirds.
    let size_group = gtk::SizeGroup::new(gtk::SizeGroupMode::Horizontal);
    size_group.add_widget(&lyrics.widget);
    size_group.add_widget(&art_page);
    size_group.add_widget(&queue.widget);

    let content = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    content.set_hexpand(true);
    content.set_vexpand(true);
    content.append(&lyrics_reveal);
    content.append(&art_page);
    content.append(&queue_reveal);

    let video = video_view::build(ui);
    let poster = poster_for(&art);
    let card = title_card(ui);
    let stage = VideoStage::default();
    stage.set_zoom(crate::ui::ui_scale::current());
    stage.set_layer(Layer::Ambient, Some(&video.ambient));
    stage.set_layer(Layer::Poster, Some(&poster));
    stage.set_layer(Layer::Video, Some(&video.picture));
    stage.set_layer(Layer::Status, Some(&video.status));
    stage.set_layer(Layer::Card, Some(&card.widget));

    let composition = gtk::Stack::builder()
        .transition_type(gtk::StackTransitionType::Crossfade)
        .transition_duration(220)
        .hexpand(true)
        .vexpand(true)
        .build();
    composition.add_named(&content, Some("columns"));
    composition.add_named(&stage, Some("stage"));

    // Suppresses the config write while the view restores saved panels or the
    // width adaptation folds one away, so a narrow window never overwrites the
    // panel layout the user actually chose.
    let syncing = Rc::new(Cell::new(true));

    let (lyrics_toggle, _lyrics_label) = toggle_button("format-justify-center-symbolic", "Lyrics");
    let (queue_toggle, queue_label) = toggle_button("view-list-symbolic", "Up Next");
    let (video_toggle, _video_label) = toggle_button("video-display-symbolic", "Video");
    video_toggle.set_tooltip_text(Some(
        "Play the song's music video, synced to your lossless audio",
    ));
    video_toggle.set_visible(crate::musicvideo::available());

    let fullscreen = gtk::Button::from_icon_name("view-fullscreen-symbolic");
    fullscreen.add_css_class("flat");
    fullscreen.set_tooltip_text(Some("Full Screen (F11)"));
    video.tools.set_visible(false);

    let swap = gtk::Button::from_icon_name("object-flip-horizontal-symbolic");
    swap.add_css_class("flat");
    swap.add_css_class("np-swap");
    swap.set_tooltip_text(Some("Swap Lyrics and Up Next sides"));

    let toggles = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    toggles.set_halign(gtk::Align::Center);
    toggles.add_css_class("np-toggles");
    toggles.append(&lyrics_toggle);
    toggles.append(&video_toggle);
    toggles.append(&queue_toggle);
    toggles.append(&swap);

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
    toolbar.add_top_bar(&header);
    toolbar.set_content(Some(&composition));
    toolbar.add_bottom_bar(&np_transport);

    let overlay = gtk::Overlay::new();
    overlay.add_css_class("np-root");
    overlay.set_child(Some(&backdrop));
    overlay.add_overlay(&scrim);
    overlay.add_overlay(&toolbar);
    overlay.add_overlay(&seek.bubble);
    overlay.add_overlay(&volume.bubble);

    let chrome = StageChrome::new(ui, &toolbar, &header, &np_transport, &stage, &card, &video);
    chrome.install(&overlay);

    let layout = Rc::new(Layout {
        ui: Rc::clone(ui),
        composition: composition.clone(),
        stage: stage.clone(),
        toolbar: toolbar.clone(),
        content: content.clone(),
        art_page: art_page.clone(),
        size_group,
        lyrics_widget: lyrics.widget.clone(),
        lyrics_reveal,
        queue_widget: queue.widget.clone(),
        queue_reveal,
        lyrics_toggle: lyrics_toggle.clone(),
        queue_toggle: queue_toggle.clone(),
        video_toggle: video_toggle.clone(),
        tools: video.tools.clone(),
        set_presentation: Rc::clone(&lyrics.set_presentation),
        set_lyrics_insets: Rc::clone(&lyrics.set_insets),
        chrome: Rc::clone(&chrome),
        in_stage: Cell::new(false),
    });
    follow_the_stage(&layout, &video, &lyrics.set_caption_layout, &poster);

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
    {
        let layout = Rc::clone(&layout);
        let set_active = Rc::clone(&queue.set_active);
        let ui = Rc::clone(ui);
        let syncing = Rc::clone(&syncing);
        queue_toggle.connect_toggled(move |button| {
            let active = button.is_active();
            set_active(active);
            layout.apply();
            if !syncing.get() {
                ui.core.config.borrow_mut().np_show_queue = active;
                ui.core.save_config();
            }
        });
    }
    {
        let layout = Rc::clone(&layout);
        let set_active = Rc::clone(&video.set_active);
        let ui = Rc::clone(ui);
        let syncing = Rc::clone(&syncing);
        video_toggle.connect_toggled(move |button| {
            let active = button.is_active();
            layout.apply();
            set_active(active);
            if !syncing.get() {
                ui.core.config.borrow_mut().np_show_video = active;
                ui.core.save_config();
            }
        });
    }
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
    {
        let (show_lyrics, show_queue, show_video) = {
            let config = ui.core.config.borrow();
            (
                config.np_show_lyrics,
                config.np_show_queue,
                config.np_show_video,
            )
        };
        lyrics_toggle.set_active(show_lyrics);
        queue_toggle.set_active(show_queue);
        video_toggle.set_active(show_video && crate::musicvideo::available());
    }
    let dock = DockFit {
        transport: transport.container.clone(),
        skips: transport.skips.to_vec(),
        volume: volume.container.clone(),
        skip_width: Cell::new(0),
        volume_width: Cell::new(0),
    };
    // Below this width, keep at most one side panel open so art stays readable.
    install_now_playing_width_adaptation(
        ui,
        &composition,
        &lyrics_toggle,
        &queue_toggle,
        dock,
        &syncing,
    );

    {
        let layout = Rc::clone(&layout);
        let swapped = ui.core.config.borrow().np_swap_sides;
        layout.apply_sides(swapped);
        let ui = Rc::clone(ui);
        swap.connect_clicked(move |_| {
            let swapped = {
                let mut config = ui.core.config.borrow_mut();
                config.np_swap_sides = !config.np_swap_sides;
                config.np_swap_sides
            };
            ui.core.save_config();
            layout.apply_sides(swapped);
        });
    }
    install_fullscreen(ui, &overlay, &fullscreen, &video, &poster);

    let update = build_updater(
        ui,
        &art,
        &backdrop,
        &title,
        &artist,
        &meta,
        &quality,
        &mix,
        &transport.love,
        &current_rel,
    );
    update();

    transport.sync_initial(ui);
    update_up_next_label(ui, &queue_label);

    wire_events(ui, &overlay, &transport, &current_rel, &queue_label, &mix, update);

    if crate::config::demo_mode() {
        if let Ok(which) = std::env::var("FLACCY_DEMO_NP_PANELS") {
            if which == "lyrics" || which == "both" || which == "1" {
                lyrics_toggle.set_active(true);
            }
            if which == "queue" || which == "both" || which == "1" {
                queue_toggle.set_active(true);
            }
        }
    }

    syncing.set(false);

    park_video_off_screen(ui, &overlay, &video_toggle);

    let page = adw::NavigationPage::builder()
        .title("Now Playing")
        .tag("now-playing")
        .child(&overlay)
        .build();
    ui.shell.push(&page);
}

/// Where the lyrics and Up Next panels live and how they are shown: columns
/// either side of the art, or layers on the video stage.
struct Layout {
    ui: Rc<Ui>,
    composition: gtk::Stack,
    stage: VideoStage,
    toolbar: adw::ToolbarView,
    content: gtk::Box,
    art_page: gtk::Widget,
    size_group: gtk::SizeGroup,
    lyrics_widget: gtk::Widget,
    lyrics_reveal: gtk::Revealer,
    queue_widget: gtk::Widget,
    queue_reveal: gtk::Revealer,
    lyrics_toggle: gtk::ToggleButton,
    queue_toggle: gtk::ToggleButton,
    video_toggle: gtk::ToggleButton,
    tools: gtk::MenuButton,
    set_presentation: Rc<dyn Fn(Presentation)>,
    set_lyrics_insets: Rc<dyn Fn(i32, i32)>,
    chrome: Rc<StageChrome>,
    in_stage: Cell<bool>,
}

impl Layout {
    /// Brings the page in line with the three toggles.
    fn apply(&self) {
        let video = self.video_toggle.is_active();
        let lyrics = self.lyrics_toggle.is_active();
        let queue = self.queue_toggle.is_active();
        if self.in_stage.replace(video) != video {
            if video {
                self.panels_to_stage();
            } else {
                self.panels_to_columns();
            }
            self.composition
                .set_visible_child_name(if video { "stage" } else { "columns" });
            self.tools.set_visible(video);
            self.chrome.set_stage(video);
        }
        if video {
            let style = LyricsStyle::from_id(&self.ui.core.config.borrow().np_video_lyrics);
            self.stage.set_lyrics(lyrics.then_some(style));
            self.stage.set_queue(queue);
        } else {
            self.lyrics_reveal.set_reveal_child(lyrics);
            self.lyrics_reveal.set_hexpand(lyrics);
            self.queue_reveal.set_reveal_child(queue);
            self.queue_reveal.set_hexpand(queue);
        }
    }

    /// Puts the lyrics on the left (or right, swapped) in both layouts.
    fn apply_sides(&self, swapped: bool) {
        let (left, right) = if swapped {
            (&self.queue_reveal, &self.lyrics_reveal)
        } else {
            (&self.lyrics_reveal, &self.queue_reveal)
        };
        left.set_transition_type(gtk::RevealerTransitionType::SlideRight);
        right.set_transition_type(gtk::RevealerTransitionType::SlideLeft);
        self.content.reorder_child_after(left, gtk::Widget::NONE);
        self.content.reorder_child_after(right, Some(&self.art_page));
        self.stage
            .set_lyrics_side(if swapped { Side::Right } else { Side::Left });
    }

    fn panels_to_stage(&self) {
        for (widget, reveal) in [
            (&self.lyrics_widget, &self.lyrics_reveal),
            (&self.queue_widget, &self.queue_reveal),
        ] {
            reveal.set_child(gtk::Widget::NONE);
            self.size_group.remove_widget(widget);
        }
        self.lyrics_widget.remove_css_class("np-side");
        self.lyrics_widget.add_css_class("np-stage-lyrics");
        self.queue_widget.add_css_class("np-stage-queue");
        self.stage.set_layer(Layer::Lyrics, Some(&self.lyrics_widget));
        self.stage.set_layer(Layer::Queue, Some(&self.queue_widget));
        self.stage.rearrange();
    }

    fn panels_to_columns(&self) {
        self.stage.set_layer(Layer::Lyrics, gtk::Widget::NONE);
        self.stage.set_layer(Layer::Queue, gtk::Widget::NONE);
        (self.set_presentation)(Presentation::Column);
        (self.set_lyrics_insets)(0, 0);
        self.lyrics_widget.remove_css_class("np-stage-lyrics");
        self.lyrics_widget.add_css_class("np-side");
        self.queue_widget.remove_css_class("np-stage-queue");
        for (widget, reveal) in [
            (&self.lyrics_widget, &self.lyrics_reveal),
            (&self.queue_widget, &self.queue_reveal),
        ] {
            widget.set_opacity(1.0);
            widget.set_child_visible(true);
            reveal.set_child(Some(widget));
            self.size_group.add_widget(widget);
        }
    }
}

/// Keeps the stage and the lyrics in step with each other: the picture's
/// shape (bars cropped away included), whether there is a picture at all or
/// only the cover to show, how far the header and dock reach, and whether the
/// lyrics are a column or captions wherever the stage put them.
fn follow_the_stage(
    layout: &Rc<Layout>,
    video: &VideoView,
    set_caption_layout: &Rc<dyn Fn(f64, f64)>,
    poster: &gtk::Picture,
) {
    let stage = layout.stage.clone();
    let show_picture: Rc<dyn Fn()> = {
        let ui = Rc::clone(&layout.ui);
        let surface = video.surface.clone();
        let picture = video.picture.clone();
        let poster = poster.clone();
        let stage = stage.clone();
        Rc::new(move || {
            let has_picture =
                ui.core.music_video.state().matched().is_some() && surface.has_frame();
            picture.set_visible(has_picture);
            poster.set_visible(!has_picture);
            stage.set_aspect(surface.aspect().unwrap_or(DEFAULT_ASPECT));
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
    let poster = poster.clone();
    let set_caption_layout = Rc::clone(set_caption_layout);
    stage.connect_arranged(move |arrangement: &Arrangement| {
        let Some(layout) = weak.upgrade() else { return };
        if !layout.in_stage.get() {
            return;
        }
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
        for widget in [picture.upcast_ref::<gtk::Widget>(), poster.upcast_ref()] {
            if arrangement.floating {
                widget.add_css_class("floating");
            } else {
                widget.remove_css_class("floating");
            }
        }
    });
}

/// The cover, shown on the stage in the picture's place while there is no
/// picture: searching, nothing found, or the stream still opening.
fn poster_for(art: &gtk::Picture) -> gtk::Picture {
    let poster = gtk::Picture::builder()
        .content_fit(gtk::ContentFit::Cover)
        .build();
    poster.set_overflow(gtk::Overflow::Hidden);
    poster.add_css_class("np-poster");
    poster.set_paintable(art.paintable().as_ref());
    let weak = poster.downgrade();
    art.connect_paintable_notify(move |art| {
        if let Some(poster) = weak.upgrade() {
            poster.set_paintable(art.paintable().as_ref());
        }
    });
    poster
}

/// The music-television title card over the picture: artist, title, album
/// and the file's quality, shown as a song starts and whenever the chrome is.
struct TitleCard {
    widget: gtk::Revealer,
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
    let body = gtk::Box::new(gtk::Orientation::Vertical, 2);
    body.add_css_class("np-card");
    body.append(&artist);
    body.append(&title);
    body.append(&meta);
    let widget = gtk::Revealer::builder()
        .transition_type(gtk::RevealerTransitionType::Crossfade)
        .transition_duration(360)
        .child(&body)
        .build();

    let fill = {
        let ui = Rc::clone(ui);
        move || {
            let Some(track) = ui.core.player.current_track() else {
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
        }
    };
    fill();
    ui.core.hub.subscribe_widget(&widget, move |_, event| {
        if matches!(event, AppEvent::TrackChanged(_)) {
            fill();
        }
    });
    TitleCard { widget }
}

/// The header, the dock and the pointer over a playing video: shown while the
/// pointer moves, a key is pressed, the video pauses or a menu is open, and
/// out of the way once the pointer rests, the way a video player behaves.
/// Over the art they never hide.
struct StageChrome {
    ui: Rc<Ui>,
    toolbar: adw::ToolbarView,
    stage: VideoStage,
    root: RefCell<Option<glib::WeakRef<gtk::Overlay>>>,
    header_hover: gtk::EventControllerMotion,
    dock_hover: gtk::EventControllerMotion,
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
        header: &adw::HeaderBar,
        dock: &gtk::Box,
        stage: &VideoStage,
        card: &TitleCard,
        video: &VideoView,
    ) -> Rc<Self> {
        let header_hover = gtk::EventControllerMotion::new();
        header.add_controller(header_hover.clone());
        let dock_hover = gtk::EventControllerMotion::new();
        dock.add_controller(dock_hover.clone());
        Rc::new(Self {
            ui: Rc::clone(ui),
            toolbar: toolbar.clone(),
            stage: stage.clone(),
            root: RefCell::new(None),
            header_hover,
            dock_hover,
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

    /// Floats the bars over the stage, or gives them back their own room
    /// over the art.
    fn set_stage(self: &Rc<Self>, active: bool) {
        self.active.set(active);
        self.toolbar.set_extend_content_to_top_edge(active);
        self.toolbar.set_extend_content_to_bottom_edge(active);
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
    /// pointer off the bars and no menu open.
    fn may_rest(&self) -> bool {
        self.active.get()
            && video_view::is_playing_video(&self.ui)
            && !self.header_hover.contains_pointer()
            && !self.dock_hover.contains_pointer()
            && !self.tools.is_active()
    }

    fn reveal(&self, shown: bool) {
        let shown = shown || !self.active.get();
        if self.shown.replace(shown) != shown {
            self.toolbar.set_reveal_top_bars(shown);
            self.toolbar.set_reveal_bottom_bars(shown);
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

    fn show_card(&self) {
        let wanted = self.active.get()
            && (self.shown.get() || self.holding_card.get())
            && self.ui.core.player.current_track().is_some();
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
    poster: &gtk::Picture,
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
    for surface in [video.picture.clone(), poster.clone().upcast()] {
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

/// The centered player lens: hero art, big title/artist, album line, and a
/// hi-res quality chip. Controls live in the persistent transport dock below.
/// Cover art grows with available width (square) so a tiny window still shows
/// a usable hero instead of locking the page to a 340px floor.
fn build_art_lens() -> (
    gtk::Widget,
    gtk::Picture,
    gtk::Label,
    gtk::Label,
    gtk::Label,
    gtk::Label,
    VersionBadge,
) {
    let art = gtk::Picture::builder()
        .content_fit(gtk::ContentFit::Cover)
        .hexpand(true)
        .vexpand(true)
        .build();
    art.set_overflow(gtk::Overflow::Hidden);
    art.add_css_class("np-art");

    let art_frame = gtk::AspectFrame::builder()
        .ratio(1.0)
        .obey_child(false)
        .halign(gtk::Align::Center)
        .valign(gtk::Align::Center)
        .hexpand(true)
        .width_request(140)
        .height_request(140)
        .child(&art)
        .build();
    art_frame.add_css_class("np-art-frame");

    let title = gtk::Label::builder()
        .xalign(0.5)
        .justify(gtk::Justification::Center)
        .wrap(true)
        .wrap_mode(pango::WrapMode::WordChar)
        .ellipsize(pango::EllipsizeMode::End)
        .lines(2)
        .build();
    title.add_css_class("np-title");
    let artist = gtk::Label::builder()
        .xalign(0.5)
        .ellipsize(pango::EllipsizeMode::End)
        .build();
    artist.add_css_class("np-artist");
    let meta = gtk::Label::builder()
        .xalign(0.5)
        .ellipsize(pango::EllipsizeMode::End)
        .build();
    meta.add_css_class("np-meta");
    meta.add_css_class("dim");
    let quality = gtk::Label::new(None);
    quality.add_css_class("np-chip");
    quality.set_halign(gtk::Align::Center);
    quality.set_visible(false);

    let mix = VersionBadge::new();
    let title_row = gtk::Box::new(gtk::Orientation::Horizontal, 10);
    title_row.set_halign(gtk::Align::Center);
    title_row.append(&title);
    title_row.append(&mix.chip);

    let text_box = gtk::Box::new(gtk::Orientation::Vertical, 6);
    text_box.set_halign(gtk::Align::Center);
    text_box.set_hexpand(true);
    text_box.append(&title_row);
    text_box.append(&mix.exported);
    text_box.append(&artist);
    text_box.append(&meta);
    text_box.append(&quality);

    let column = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(18)
        .halign(gtk::Align::Fill)
        .valign(gtk::Align::Center)
        .hexpand(true)
        .margin_top(24)
        .margin_bottom(24)
        .margin_start(16)
        .margin_end(16)
        .build();
    column.append(&art_frame);
    column.append(&text_box);

    let clamp = adw::Clamp::builder()
        .maximum_size(480)
        .tightening_threshold(200)
        .child(&column)
        .build();
    let scroll = gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::Never)
        .hexpand(true)
        .vexpand(true)
        .child(&clamp)
        .build();
    (scroll.upcast(), art, title, artist, meta, quality, mix)
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

/// When Now Playing is squeezed, auto-collapse side panels so the hero art is
/// never crushed between two full columns on a narrow window, and fold away
/// the volume cluster, then the skip buttons, so the transport buttons keep
/// their centerline.
fn install_now_playing_width_adaptation(
    ui: &Rc<Ui>,
    content: &impl IsA<gtk::Widget>,
    lyrics_toggle: &gtk::ToggleButton,
    queue_toggle: &gtk::ToggleButton,
    dock: DockFit,
    syncing: &Rc<Cell<bool>>,
) {
    let ui = Rc::clone(ui);
    let lyrics_toggle = lyrics_toggle.clone();
    let queue_toggle = queue_toggle.clone();
    let dock = Rc::new(dock);
    let syncing = Rc::clone(syncing);
    crate::ui::resize::watch_width(content, move |width, previous| {
        if width < 640 && lyrics_toggle.is_active() && queue_toggle.is_active() {
            syncing.set(true);
            queue_toggle.set_active(false);
            syncing.set(false);
        } else if width >= 640 && previous > 0 && previous < 640 {
            restore_chosen_queue(&ui, &queue_toggle, &syncing);
        }
        dock.apply(width);
    });
}

/// Widening again restores whatever the person actually chose, otherwise a
/// panel folded away at phone width never returns.
fn restore_chosen_queue(ui: &Rc<Ui>, queue_toggle: &gtk::ToggleButton, syncing: &Cell<bool>) {
    let wanted = ui.core.config.borrow().np_show_queue;
    if wanted && !queue_toggle.is_active() {
        syncing.set(true);
        queue_toggle.set_active(true);
        syncing.set(false);
    }
}

/// Parks the video pipeline whenever Now Playing isn't on screen — another
/// page, or a window the compositor has minimised or hidden — so nothing is
/// decoded that nobody sees, and resumes it on the way back in.
fn park_video_off_screen(ui: &Rc<Ui>, host: &gtk::Overlay, video_toggle: &gtk::ToggleButton) {
    let update: Rc<dyn Fn()> = {
        let ui = Rc::clone(ui);
        let host = host.downgrade();
        let video_toggle = video_toggle.downgrade();
        Rc::new(move || {
            let (Some(host), Some(video_toggle)) = (host.upgrade(), video_toggle.upgrade()) else {
                return;
            };
            let showing =
                host.is_mapped() && video_toggle.is_active() && !ui.window.is_suspended();
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

/// Repaints the artwork (sharp, plus the pre-blurred backdrop), text, and
/// quality chip for the current track; reused on open and on every
/// TrackChanged.
#[allow(clippy::too_many_arguments)]
fn build_updater(
    ui: &Rc<Ui>,
    art: &gtk::Picture,
    backdrop: &gtk::Picture,
    title: &gtk::Label,
    artist: &gtk::Label,
    meta: &gtk::Label,
    quality: &gtk::Label,
    mix: &VersionBadge,
    love: &gtk::Button,
    current_rel: &Rc<RefCell<Option<String>>>,
) -> Updater {
    let ui = Rc::clone(ui);
    let art = art.clone();
    let backdrop = backdrop.clone();
    let title = title.clone();
    let artist = artist.clone();
    let meta = meta.clone();
    let quality = quality.clone();
    let mix = mix.clone();
    let love = love.clone();
    let current_rel = Rc::clone(current_rel);
    Rc::new(move || {
        let Some(track) = ui.core.player.current_track() else {
            title.set_label("Not Playing");
            artist.set_label("");
            meta.set_label("");
            quality.set_visible(false);
            mix.hide();
            love.set_sensitive(false);
            *current_rel.borrow_mut() = None;
            return;
        };
        title.set_label(&track.title);
        artist.set_label(&track.artist);
        meta.set_label(&track.album);
        let fresh = ui
            .core
            .library
            .borrow()
            .track_by_rel_path(&track.rel_path)
            .cloned();
        mix.show(fresh.as_ref().unwrap_or(&track));
        match track.quality_badge() {
            Some(badge) => {
                quality.set_label(&badge);
                quality.set_visible(true);
            }
            None => quality.set_visible(false),
        }
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
            .request(&track.album, &track.artist, 340, move |texture, _| {
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
    mix: &VersionBadge,
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
    let mix = mix.clone();
    hub.subscribe_widget(host, move |_, event| match event {
        AppEvent::TrackChanged(_) => {
            update();
            update_up_next_label(&ui, &queue_label);
        }
        AppEvent::LibraryReloaded => {
            let playing = ui.core.player.current_track().and_then(|track| {
                ui.core.library.borrow().track_by_rel_path(&track.rel_path).cloned()
            });
            if let Some(track) = playing {
                mix.show(&track);
            }
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
