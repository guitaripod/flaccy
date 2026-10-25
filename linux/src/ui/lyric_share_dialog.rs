//! The Share Lyrics dialog: a live preview playing the song's own audio on
//! the left, the template, format, colours, font, switches and lines on the
//! right, Save Image… and Save Video… at the foot. Mirrors the iPhone sheet
//! (`Features/LyricShare/LyricShareViewController.swift`) and the Mac window;
//! Linux saves to a file where the Apple clients open a share sheet.

use crate::library::Track;
use crate::lyric_share::export::{self, ClipAudio, ExportError};
use crate::lyric_share::render::Renderer;
use crate::lyric_share::{copy, Cover, Scene};
use crate::lyrics::{Lyrics, LyricsResult};
use crate::ui::Ui;
use adw::prelude::*;
use flaccy_shared::lyric_share::{
    self as share, Analysis, Color, Format, Palette, Selection, Style, Template, Theme, Typeface,
    Window,
};
use flaccy_shared::lyrics::Document;
use gst::prelude::*;
use gtk::{gdk, gio, glib};
use std::cell::{Cell, RefCell};
use std::path::PathBuf;
use std::rc::Rc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

/// How long a change of lines waits before the audio is read again, so a run
/// of clicks reads it once.
const RELOAD_DELAY: Duration = Duration::from_millis(250);
/// The cover size asked of the artwork cache, in pixels.
const COVER_SIZE: u32 = 600;
/// How wide the preview column is.
const PREVIEW_WIDTH: i32 = 380;

struct State {
    track: Track,
    lyrics: Lyrics,
    document: Arc<Document>,
    plain: Option<Arc<Vec<String>>>,
    selection: Selection,
    plain_start: f64,
    style: Style,
    cover: Option<Arc<Cover>>,
    samples: Vec<Color>,
    audio: Option<Arc<ClipAudio>>,
    analysis: Arc<Analysis>,
    failure: Option<ExportError>,
    loading: bool,
    generation: u64,
    preview_path: Option<PathBuf>,
    renderer: Option<(Renderer, i32)>,
    export_cancel: Option<Arc<AtomicBool>>,
}

impl State {
    fn duration(&self) -> f64 {
        self.track.duration.max(0.0)
    }

    fn window(&self) -> Window {
        match &self.plain {
            Some(_) => share::plain_window(self.plain_start, self.duration()),
            None => share::window(
                self.selection,
                &self.document,
                self.lyrics.offset_seconds(),
                self.duration(),
            ),
        }
    }

    fn scene(&self) -> Scene {
        Scene {
            document: Arc::clone(&self.document),
            selection: self.selection,
            plain_lines: self.plain.clone(),
            window: self.window(),
            style: self.style,
            palette: Palette::make(self.style.theme, &self.samples),
            title: self.track.title.clone(),
            artist: self.track.artist.clone(),
            cover: self.cover.clone(),
            analysis: Arc::clone(&self.analysis),
        }
    }

    fn picker_lines(&self) -> Vec<String> {
        match &self.plain {
            Some(lines) => lines.as_ref().clone(),
            None => self
                .document
                .lines
                .iter()
                .map(|line| if line.is_interlude() { "\u{266A}".to_string() } else { line.text.clone() })
                .collect(),
        }
    }

    fn is_pickable(&self, index: usize) -> bool {
        match &self.plain {
            Some(lines) => index < lines.len(),
            None => share::is_selectable(index, &self.document),
        }
    }
}

struct Dialog {
    ui: Rc<Ui>,
    dialog: adw::Dialog,
    state: RefCell<State>,
    preview: gtk::DrawingArea,
    aspect: gtk::AspectFrame,
    play: gtk::Button,
    spinner: adw::Spinner,
    note: gtk::Label,
    rows: RefCell<Vec<(gtk::ListBoxRow, gtk::Label, gtk::Image)>>,
    hint: gtk::Label,
    start_label: gtk::Label,
    template: adw::ToggleGroup,
    format: adw::ToggleGroup,
    typeface: adw::ToggleGroup,
    swatches: RefCell<Vec<(Theme, gtk::ToggleButton, gtk::DrawingArea)>>,
    switches: RefCell<Vec<adw::SwitchRow>>,
    buttons: gtk::Box,
    save_video: gtk::Button,
    progress_box: gtk::Box,
    progress: gtk::ProgressBar,
    player: RefCell<Option<gst::Element>>,
    paused_song: Cell<bool>,
    tick: RefCell<Option<gtk::TickCallbackId>>,
    shown_frame: Cell<Option<usize>>,
    reload: RefCell<Option<glib::SourceId>>,
}

/// Opens the dialog for the song playing now, reading its lyrics first.
/// `line` picks the line the clip starts from.
pub fn present_for_current(ui: &Rc<Ui>, line: Option<usize>) {
    let Some(track) = ui.core.player.current_track() else {
        ui.core.toast("Play a song with lyrics to share them.");
        return;
    };
    let (tx, rx) = async_channel::bounded::<LyricsResult>(1);
    let db_path = ui.core.db_path.clone();
    let music_root = ui.core.music_root();
    let for_thread = track.clone();
    std::thread::spawn(move || {
        let _ = tx.send_blocking(crate::lyrics::fetch_blocking(&db_path, &music_root, &for_thread));
    });
    let ui = Rc::clone(ui);
    glib::spawn_future_local(async move {
        match rx.recv().await {
            Ok(LyricsResult::Found(lyrics)) => present(&ui, track, lyrics, line),
            _ => ui.core.toast(&format!(
                "No lyrics to share for “{}” — none were found in its tags, beside the file or on lrclib.net.",
                track.title
            )),
        }
    });
}

/// Opens the dialog for `track`, which must be the one playing, with the
/// lyrics a panel already holds.
pub fn present(ui: &Rc<Ui>, track: Track, lyrics: Lyrics, line: Option<usize>) {
    let document = Arc::new(lyrics.document.clone());
    let position = ui.core.player.position();
    let (selection, plain, plain_start) = if document.has_synced() {
        let start = line
            .filter(|&index| share::is_selectable(index, &document))
            .map(|index| document.lines[index].start)
            .or_else(|| position.map(|position| lyrics.song_time(position)));
        let Some(selection) = share::default_selection(&document, start) else { return };
        (selection, None, 0.0)
    } else if let Some(plain) = document.plain.as_deref() {
        let lines = share::plain_lines(plain);
        let Some(selection) = share::default_plain_selection(&lines) else { return };
        (selection, Some(Arc::new(lines)), position.unwrap_or(track.duration * 0.3))
    } else {
        ui.core.toast(&format!("“{}” has no words to share.", track.title));
        return;
    };
    let style = Style::decode(&ui.core.config.borrow().lyric_share_style);
    let state = State {
        track,
        lyrics,
        document,
        plain,
        selection,
        plain_start,
        style,
        cover: None,
        samples: Vec::new(),
        audio: None,
        analysis: Arc::new(Analysis { bands: Vec::new(), levels: Vec::new() }),
        failure: None,
        loading: false,
        generation: 0,
        preview_path: None,
        renderer: None,
        export_cancel: None,
    };
    let dialog = build(ui, state);
    let keep = RefCell::new(Some(Rc::clone(&dialog)));
    dialog.dialog.connect_closed(move |_| {
        keep.borrow_mut().take();
    });
    dialog.request_cover();
    dialog.reload_audio(Duration::ZERO);
    dialog.dialog.present(Some(&ui.window));
}

fn section(title: &str, child: &impl IsA<gtk::Widget>) -> gtk::Box {
    let column = gtk::Box::new(gtk::Orientation::Vertical, 8);
    let label = gtk::Label::builder().label(title).xalign(0.0).build();
    label.add_css_class("heading");
    column.append(&label);
    column.append(child);
    column
}

fn toggle_group<T: Copy + 'static>(items: &[T], key: fn(T) -> &'static str, label: fn(T) -> &'static str) -> adw::ToggleGroup {
    let group = adw::ToggleGroup::new();
    group.set_homogeneous(true);
    for &item in items {
        group.add(adw::Toggle::builder().name(key(item)).label(label(item)).build());
    }
    group
}

fn build(ui: &Rc<Ui>, state: State) -> Rc<Dialog> {
    let dialog = adw::Dialog::builder()
        .title(copy::SHEET_TITLE)
        .content_width(1040)
        .content_height(760)
        .build();

    let preview = gtk::DrawingArea::new();
    preview.set_size_request(160, 160);
    preview.set_hexpand(true);
    preview.set_vexpand(true);
    let stage = gtk::Overlay::new();
    stage.set_child(Some(&preview));
    let aspect = gtk::AspectFrame::builder()
        .ratio(9.0 / 16.0)
        .obey_child(false)
        .child(&stage)
        .vexpand(true)
        .build();
    let play = gtk::Button::from_icon_name("media-playback-start-symbolic");
    play.add_css_class("circular");
    play.add_css_class("osd");
    play.set_halign(gtk::Align::End);
    play.set_valign(gtk::Align::End);
    play.set_margin_end(12);
    play.set_margin_bottom(12);
    play.set_tooltip_text(Some(copy::PLAY_PREVIEW));
    let spinner = adw::Spinner::new();
    spinner.set_halign(gtk::Align::End);
    spinner.set_valign(gtk::Align::End);
    spinner.set_margin_end(18);
    spinner.set_margin_bottom(18);
    spinner.set_size_request(24, 24);
    stage.add_overlay(&play);
    stage.add_overlay(&spinner);
    let note = gtk::Label::builder().wrap(true).justify(gtk::Justification::Center).visible(false).build();
    note.add_css_class("dim-label");
    note.add_css_class("caption");
    let preview_column = gtk::Box::new(gtk::Orientation::Vertical, 8);
    preview_column.set_size_request(PREVIEW_WIDTH, -1);
    preview_column.set_margin_start(18);
    preview_column.set_margin_top(6);
    preview_column.set_margin_bottom(12);
    preview_column.append(&aspect);
    preview_column.append(&note);

    let template = toggle_group(&Template::ALL, Template::key, copy::template);
    for (index, item) in Template::ALL.into_iter().enumerate() {
        if let Some(toggle) = template.toggle(index as u32) {
            toggle.set_icon_name(Some(copy::template_icon(item)));
            toggle.set_tooltip(copy::template_hint(item));
        }
    }
    let format = toggle_group(&Format::ALL, Format::key, copy::format);
    let typeface = toggle_group(&Typeface::ALL, Typeface::key, copy::typeface);

    let swatch_row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    swatch_row.set_homogeneous(true);
    let mut swatches = Vec::new();
    let mut leader: Option<gtk::ToggleButton> = None;
    for theme in Theme::ALL {
        let area = gtk::DrawingArea::builder().content_width(36).content_height(36).halign(gtk::Align::Center).build();
        let label = gtk::Label::new(Some(copy::theme(theme)));
        label.add_css_class("caption");
        let column = gtk::Box::new(gtk::Orientation::Vertical, 4);
        column.append(&area);
        column.append(&label);
        let button = gtk::ToggleButton::builder().child(&column).build();
        button.add_css_class("flat");
        button.set_tooltip_text(Some(copy::theme(theme)));
        if let Some(leader) = &leader {
            button.set_group(Some(leader));
        } else {
            leader = Some(button.clone());
        }
        swatch_row.append(&button);
        swatches.push((theme, button, area));
    }

    let switch_list = gtk::ListBox::new();
    switch_list.add_css_class("boxed-list");
    switch_list.set_selection_mode(gtk::SelectionMode::None);
    let mut switches = Vec::new();
    for title in [copy::SHOW_COVER, copy::SHOW_VISUALIZER, copy::SHOW_MARK] {
        let row = adw::SwitchRow::builder().title(title).build();
        switch_list.append(&row);
        switches.push(row);
    }

    let hint = gtk::Label::builder().xalign(0.0).wrap(true).build();
    hint.add_css_class("dim-label");
    hint.add_css_class("caption");
    let start_label = gtk::Label::builder().xalign(0.0).build();
    start_label.add_css_class("caption");
    let lines_column = gtk::Box::new(gtk::Orientation::Vertical, 8);
    lines_column.append(&hint);
    let start_scale = gtk::Scale::with_range(
        gtk::Orientation::Horizontal,
        0.0,
        (state.duration() - share::PLAIN_DURATION).max(1.0),
        1.0,
    );
    if state.plain.is_some() {
        start_scale.set_value(state.plain_start);
        lines_column.append(&start_label);
        lines_column.append(&start_scale);
    }
    let line_list = gtk::ListBox::new();
    line_list.add_css_class("boxed-list");
    line_list.set_selection_mode(gtk::SelectionMode::None);
    let mut rows = Vec::new();
    for (index, text) in state.picker_lines().into_iter().enumerate() {
        let label = gtk::Label::builder().label(text).xalign(0.0).wrap(true).hexpand(true).build();
        let check = gtk::Image::from_icon_name("object-select-symbolic");
        let content = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        content.set_margin_top(8);
        content.set_margin_bottom(8);
        content.set_margin_start(12);
        content.set_margin_end(12);
        content.append(&label);
        content.append(&check);
        let row = gtk::ListBoxRow::builder().child(&content).activatable(state.is_pickable(index)).build();
        row.set_sensitive(state.is_pickable(index));
        line_list.append(&row);
        rows.push((row, label, check));
    }
    lines_column.append(&line_list);

    let controls = gtk::Box::new(gtk::Orientation::Vertical, 18);
    controls.set_margin_start(18);
    controls.set_margin_end(18);
    controls.set_margin_top(6);
    controls.set_margin_bottom(18);
    controls.append(&section(copy::TEMPLATE_HEADER, &template));
    controls.append(&section(copy::FORMAT_HEADER, &format));
    controls.append(&section(copy::COLORS_HEADER, &swatch_row));
    controls.append(&section(copy::FONT_HEADER, &typeface));
    controls.append(&switch_list);
    controls.append(&section(copy::LINES_HEADER, &lines_column));
    let scroller = gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::Never)
        .child(&controls)
        .hexpand(true)
        .vexpand(true)
        .build();

    let body = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    body.append(&preview_column);
    body.append(&scroller);

    let save_image = gtk::Button::with_label(copy::SAVE_IMAGE);
    save_image.add_css_class("pill");
    let save_video = gtk::Button::with_label(copy::SAVE_VIDEO);
    save_video.add_css_class("pill");
    save_video.add_css_class("suggested-action");
    let buttons = gtk::Box::new(gtk::Orientation::Horizontal, 10);
    buttons.set_halign(gtk::Align::End);
    buttons.append(&save_image);
    buttons.append(&save_video);
    let progress = gtk::ProgressBar::new();
    progress.set_hexpand(true);
    progress.set_valign(gtk::Align::Center);
    let making = gtk::Label::new(Some(copy::MAKING));
    making.add_css_class("caption-heading");
    let cancel = gtk::Button::with_label("Cancel");
    cancel.add_css_class("pill");
    let progress_box = gtk::Box::new(gtk::Orientation::Horizontal, 12);
    progress_box.append(&making);
    progress_box.append(&progress);
    progress_box.append(&cancel);
    progress_box.set_visible(false);
    progress_box.set_hexpand(true);
    let footer = gtk::Box::new(gtk::Orientation::Horizontal, 12);
    footer.set_margin_start(18);
    footer.set_margin_end(18);
    footer.set_margin_top(10);
    footer.set_margin_bottom(14);
    footer.append(&progress_box);
    footer.append(&buttons);
    buttons.set_hexpand(true);

    let toolbar = adw::ToolbarView::new();
    toolbar.add_top_bar(&adw::HeaderBar::new());
    toolbar.set_content(Some(&body));
    toolbar.add_bottom_bar(&footer);
    dialog.set_child(Some(&toolbar));

    let this = Rc::new(Dialog {
        ui: Rc::clone(ui),
        dialog,
        state: RefCell::new(state),
        preview,
        aspect,
        play,
        spinner,
        note,
        rows: RefCell::new(rows),
        hint,
        start_label,
        template,
        format,
        typeface,
        swatches: RefCell::new(swatches),
        switches: RefCell::new(switches),
        buttons,
        save_video,
        progress_box,
        progress,
        player: RefCell::new(None),
        paused_song: Cell::new(false),
        tick: RefCell::new(None),
        shown_frame: Cell::new(None),
        reload: RefCell::new(None),
    });
    this.wire(&line_list, &start_scale, &save_image, &cancel);
    this.apply_style();
    this.refresh_lines();
    this
}

impl Dialog {
    fn wire(self: &Rc<Self>, line_list: &gtk::ListBox, start_scale: &gtk::Scale, save_image: &gtk::Button, cancel: &gtk::Button) {
        let weak = Rc::downgrade(self);
        self.preview.set_draw_func(move |area, cr, width, height| {
            if let Some(this) = weak.upgrade() {
                this.draw(area, cr, width, height);
            }
        });
        let weak = Rc::downgrade(self);
        self.play.connect_clicked(move |_| {
            if let Some(this) = weak.upgrade() {
                this.toggle_preview();
            }
        });
        let click = gtk::GestureClick::new();
        let weak = Rc::downgrade(self);
        click.connect_released(move |_, _, _, _| {
            if let Some(this) = weak.upgrade() {
                this.toggle_preview();
            }
        });
        self.preview.add_controller(click);

        let weak = Rc::downgrade(self);
        self.template.connect_active_name_notify(move |group| {
            let Some(this) = weak.upgrade() else { return };
            if let Some(template) = group.active_name().and_then(|name| Template::from_key(&name)) {
                this.change(|style| style.template = template);
            }
        });
        let weak = Rc::downgrade(self);
        self.format.connect_active_name_notify(move |group| {
            let Some(this) = weak.upgrade() else { return };
            if let Some(format) = group.active_name().and_then(|name| Format::from_key(&name)) {
                this.change(|style| style.format = format);
            }
        });
        let weak = Rc::downgrade(self);
        self.typeface.connect_active_name_notify(move |group| {
            let Some(this) = weak.upgrade() else { return };
            if let Some(typeface) = group.active_name().and_then(|name| Typeface::from_key(&name)) {
                this.change(|style| style.typeface = typeface);
            }
        });
        for (theme, button, area) in self.swatches.borrow().iter() {
            let theme = *theme;
            let weak = Rc::downgrade(self);
            button.connect_toggled(move |button| {
                if !button.is_active() {
                    return;
                }
                if let Some(this) = weak.upgrade() {
                    this.change(|style| style.theme = theme);
                }
            });
            let weak = Rc::downgrade(self);
            area.set_draw_func(move |_, cr, width, height| {
                let Some(this) = weak.upgrade() else { return };
                let state = this.state.borrow();
                let palette = Palette::make(theme, &state.samples);
                draw_swatch(cr, &palette, width as f64, height as f64);
            });
        }
        for (index, row) in self.switches.borrow().iter().enumerate() {
            let weak = Rc::downgrade(self);
            row.connect_active_notify(move |row| {
                let Some(this) = weak.upgrade() else { return };
                let on = row.is_active();
                this.change(|style| match index {
                    0 => style.show_artwork = on,
                    1 => style.show_visualizer = on,
                    _ => style.show_mark = on,
                });
            });
        }
        let weak = Rc::downgrade(self);
        line_list.connect_row_activated(move |_, row| {
            if let Some(this) = weak.upgrade() {
                this.toggle_line(row.index().max(0) as usize);
            }
        });
        let weak = Rc::downgrade(self);
        start_scale.connect_value_changed(move |scale| {
            let Some(this) = weak.upgrade() else { return };
            {
                let mut state = this.state.borrow_mut();
                let latest = (state.duration() - share::PLAIN_DURATION).max(0.0);
                state.plain_start = scale.value().clamp(0.0, latest);
                state.renderer = None;
            }
            this.refresh_lines();
            this.reload_audio(RELOAD_DELAY);
        });
        let weak = Rc::downgrade(self);
        save_image.connect_clicked(move |_| {
            if let Some(this) = weak.upgrade() {
                this.save(false);
            }
        });
        let weak = Rc::downgrade(self);
        self.save_video.connect_clicked(move |_| {
            if let Some(this) = weak.upgrade() {
                this.save(true);
            }
        });
        let weak = Rc::downgrade(self);
        cancel.connect_clicked(move |_| {
            if let Some(this) = weak.upgrade() {
                if let Some(flag) = &this.state.borrow().export_cancel {
                    flag.store(true, Ordering::Relaxed);
                }
            }
        });
        let keys = gtk::EventControllerKey::new();
        let weak = Rc::downgrade(self);
        keys.connect_key_pressed(move |_, key, _, _| {
            if key == gdk::Key::space {
                if let Some(this) = weak.upgrade() {
                    this.toggle_preview();
                }
                return glib::Propagation::Stop;
            }
            glib::Propagation::Proceed
        });
        self.dialog.add_controller(keys);
        let weak = Rc::downgrade(self);
        self.dialog.connect_closed(move |_| {
            if let Some(this) = weak.upgrade() {
                this.teardown();
            }
        });
    }

    fn change(&self, edit: impl FnOnce(&mut Style)) {
        let style = {
            let mut state = self.state.borrow_mut();
            let mut style = state.style;
            edit(&mut style);
            if style == state.style {
                return;
            }
            state.style = style;
            state.renderer = None;
            style
        };
        self.ui.core.config.borrow_mut().lyric_share_style = style.encode();
        self.ui.core.save_config();
        self.apply_style();
        self.preview.queue_draw();
    }

    fn apply_style(&self) {
        let style = self.state.borrow().style;
        self.template.set_active_name(Some(style.template.key()));
        self.format.set_active_name(Some(style.format.key()));
        self.typeface.set_active_name(Some(style.typeface.key()));
        for (theme, button, area) in self.swatches.borrow().iter() {
            button.set_active(*theme == style.theme);
            area.queue_draw();
        }
        let flags = [style.show_artwork, style.show_visualizer, style.show_mark];
        for (row, on) in self.switches.borrow().iter().zip(flags) {
            if row.is_active() != on {
                row.set_active(on);
            }
        }
        self.aspect
            .set_ratio(style.format.pixel_width() as f32 / style.format.pixel_height() as f32);
    }

    fn toggle_line(self: &Rc<Self>, index: usize) {
        {
            let mut state = self.state.borrow_mut();
            let next = match &state.plain {
                Some(lines) => share::toggle_plain(state.selection, index, lines.len()),
                None => share::toggle(state.selection, index, &state.document),
            };
            if next == state.selection {
                return;
            }
            state.selection = next;
            state.renderer = None;
        }
        self.refresh_lines();
        self.reload_audio(RELOAD_DELAY);
    }

    fn refresh_lines(&self) {
        let state = self.state.borrow();
        for (index, (row, label, check)) in self.rows.borrow().iter().enumerate() {
            let chosen = state.selection.contains(index) && state.is_pickable(index);
            check.set_visible(chosen);
            if chosen {
                label.remove_css_class("dim-label");
                label.add_css_class("heading");
                row.add_css_class("accent");
            } else {
                label.add_css_class("dim-label");
                label.remove_css_class("heading");
                row.remove_css_class("accent");
            }
        }
        self.hint.set_label(&copy::lines_hint(state.window().duration, state.plain.is_none()));
        self.start_label.set_label(&copy::starts_at(state.plain_start));
    }

    fn request_cover(self: &Rc<Self>) {
        let (album, artist) = {
            let state = self.state.borrow();
            (state.track.album.clone(), state.track.artist.clone())
        };
        let weak = Rc::downgrade(self);
        self.ui.core.artwork.request(&album, &artist, COVER_SIZE, move |texture, _| {
            let Some(this) = weak.upgrade() else { return };
            let Some(texture) = texture else { return };
            let (width, height) = (texture.width(), texture.height());
            let stride = width as usize * 4;
            let mut data = vec![0u8; stride * height as usize];
            texture.download(&mut data, stride);
            let cover = Cover { data, width, height, stride: stride as i32 };
            {
                let mut state = this.state.borrow_mut();
                state.samples = cover.samples();
                state.cover = Some(Arc::new(cover));
                state.renderer = None;
            }
            this.apply_style();
            this.preview.queue_draw();
        });
    }

    /// Reads the window's audio again off the main thread after `delay`: the
    /// file itself, or a song on a server through the loopback proxy.
    fn reload_audio(self: &Rc<Self>, delay: Duration) {
        if let Some(source) = self.reload.borrow_mut().take() {
            source.remove();
        }
        let weak = Rc::downgrade(self);
        let source = glib::timeout_add_local_once(delay, move || {
            if let Some(this) = weak.upgrade() {
                this.reload.borrow_mut().take();
                this.read_audio();
            }
        });
        *self.reload.borrow_mut() = Some(source);
        let mut state = self.state.borrow_mut();
        state.loading = true;
        state.failure = None;
        drop(state);
        self.show_audio_state();
    }

    fn read_audio(self: &Rc<Self>) {
        let (input, window, rate, generation) = {
            let mut state = self.state.borrow_mut();
            state.generation += 1;
            let input = if crate::remote::is_remote(&state.track.rel_path) {
                crate::remote::proxy_uri(&state.track.rel_path)
            } else {
                Some(state.track.abs_path(&self.ui.core.music_root()).to_string_lossy().into_owned())
            };
            let rate = export::target_rate(state.track.sample_rate.map(|rate| rate as u32));
            (input, state.window(), rate, state.generation)
        };
        let Some(input) = input else {
            self.finish_audio(generation, Err(ExportError::Unreadable("the server is out of reach".into())));
            return;
        };
        let (tx, rx) = async_channel::bounded(1);
        std::thread::spawn(move || {
            let result = export::load_audio(&input, &window, rate).map(|audio| {
                let analysis = share::analyze(&audio.mono, audio.sample_rate as f64, share::frame_count(&window), share::FPS);
                let preview = std::env::temp_dir().join(format!("flaccy-lyric-preview-{}-{generation}.wav", std::process::id()));
                let written = export::write_wav(&audio, &preview).is_ok();
                (audio, analysis, written.then_some(preview))
            });
            let _ = tx.send_blocking(result);
        });
        let weak = Rc::downgrade(self);
        glib::spawn_future_local(async move {
            let Ok(result) = rx.recv().await else { return };
            if let Some(this) = weak.upgrade() {
                this.finish_audio(generation, result);
            }
        });
    }

    fn finish_audio(self: &Rc<Self>, generation: u64, result: Result<(ClipAudio, Analysis, Option<PathBuf>), ExportError>) {
        {
            let mut state = self.state.borrow_mut();
            if state.generation != generation {
                return;
            }
            state.loading = false;
            state.renderer = None;
            if let Some(old) = state.preview_path.take() {
                let _ = std::fs::remove_file(old);
            }
            match result {
                Ok((audio, analysis, preview)) => {
                    state.audio = Some(Arc::new(audio));
                    state.analysis = Arc::new(analysis);
                    state.preview_path = preview;
                    state.failure = None;
                }
                Err(error) => {
                    state.audio = None;
                    state.analysis = Arc::new(Analysis { bands: Vec::new(), levels: Vec::new() });
                    state.failure = Some(error);
                }
            }
        }
        let playing = self.preview_playing();
        self.stop_player();
        self.load_player();
        if playing {
            self.start_player();
        }
        self.show_audio_state();
        self.preview.queue_draw();
        self.save_for_demo();
    }

    /// `FLACCY_DEMO_LYRIC_SHARE_SAVE=<path.mp4>` saves the clip there once its
    /// audio is in, without the file chooser, so the whole path from the
    /// dialog to the file can be driven headlessly.
    fn save_for_demo(self: &Rc<Self>) {
        static SAVED: AtomicBool = AtomicBool::new(false);
        let Some(path) = std::env::var_os("FLACCY_DEMO_LYRIC_SHARE_SAVE") else { return };
        if self.state.borrow().audio.is_none() || SAVED.swap(true, Ordering::Relaxed) {
            return;
        }
        self.export_to(PathBuf::from(path), true);
    }

    fn show_audio_state(&self) {
        let state = self.state.borrow();
        self.spinner.set_visible(state.loading);
        self.play.set_visible(!state.loading && state.audio.is_some());
        self.save_video.set_sensitive(state.audio.is_some() && state.export_cancel.is_none());
        match (&state.failure, state.loading) {
            (Some(error), _) => {
                self.note.set_label(&copy::audio_failure(error, &state.track.title));
                self.note.set_visible(true);
            }
            (None, true) => {
                self.note.set_label(copy::READING_AUDIO);
                self.note.set_visible(true);
            }
            (None, false) => self.note.set_visible(false),
        }
    }

    fn load_player(&self) {
        let Some(path) = self.state.borrow().preview_path.clone() else { return };
        let Ok(uri) = glib::filename_to_uri(&path, None::<&str>) else { return };
        let Ok(playbin) = gst::ElementFactory::make("playbin").property("uri", uri.as_str()).build() else {
            return;
        };
        let _ = playbin.set_state(gst::State::Paused);
        if let Some(bus) = playbin.bus() {
            let weak = playbin.downgrade();
            let _ = bus.add_watch_local(move |_, message| {
                if let gst::MessageView::Eos(_) = message.view() {
                    if let Some(playbin) = weak.upgrade() {
                        let _ = playbin.seek_simple(gst::SeekFlags::FLUSH | gst::SeekFlags::ACCURATE, gst::ClockTime::ZERO);
                    }
                }
                glib::ControlFlow::Continue
            });
        }
        *self.player.borrow_mut() = Some(playbin);
    }

    fn preview_playing(&self) -> bool {
        self.player
            .borrow()
            .as_ref()
            .is_some_and(|playbin| playbin.current_state() == gst::State::Playing || playbin.pending_state() == gst::State::Playing)
    }

    fn preview_time(&self) -> f64 {
        self.player
            .borrow()
            .as_ref()
            .and_then(|playbin| playbin.query_position::<gst::ClockTime>())
            .map(|position| position.nseconds() as f64 / 1e9)
            .unwrap_or(0.0)
    }

    fn start_player(self: &Rc<Self>) {
        let Some(playbin) = self.player.borrow().clone() else { return };
        if self.ui.core.player.is_playing() {
            self.ui.core.player.toggle_play_pause();
            self.paused_song.set(true);
        }
        let _ = playbin.set_state(gst::State::Playing);
        self.start_tick();
        self.play.set_icon_name("media-playback-pause-symbolic");
        self.play.set_tooltip_text(Some(copy::PAUSE_PREVIEW));
    }

    fn pause_player(&self) {
        if let Some(playbin) = self.player.borrow().as_ref() {
            let _ = playbin.set_state(gst::State::Paused);
        }
        self.stop_tick();
        self.play.set_icon_name("media-playback-start-symbolic");
        self.play.set_tooltip_text(Some(copy::PLAY_PREVIEW));
        self.preview.queue_draw();
    }

    fn stop_player(&self) {
        if let Some(playbin) = self.player.borrow_mut().take() {
            let _ = playbin.set_state(gst::State::Null);
        }
        self.stop_tick();
    }

    fn toggle_preview(self: &Rc<Self>) {
        if self.preview_playing() {
            self.pause_player();
        } else {
            self.start_player();
        }
    }

    /// Redraws the preview while it plays, only when the clip has reached a
    /// new frame.
    fn start_tick(self: &Rc<Self>) {
        if self.tick.borrow().is_some() {
            return;
        }
        let weak = Rc::downgrade(self);
        let id = self.preview.add_tick_callback(move |area, _| {
            let Some(this) = weak.upgrade() else { return glib::ControlFlow::Break };
            let frame = this.frame_index(&this.state.borrow());
            if this.shown_frame.get() != Some(frame) {
                area.queue_draw();
            }
            glib::ControlFlow::Continue
        });
        *self.tick.borrow_mut() = Some(id);
    }

    fn stop_tick(&self) {
        if let Some(id) = self.tick.borrow_mut().take() {
            id.remove();
        }
    }

    /// The frame the preview shows: where the preview player is, or, while it
    /// is paused, the first line just before it ends, fully sung.
    fn frame_index(&self, state: &State) -> usize {
        let frames = share::frame_count(&state.window());
        if self.preview_playing() {
            return ((self.preview_time() * share::FPS as f64) as usize).min(frames - 1);
        }
        if state.plain.is_some() {
            return (share::FPS as usize).min(frames - 1);
        }
        let first = &state.document.lines[state.selection.first];
        let sung = (first.end - 0.1).max(first.start + share::ENTRANCE_DURATION);
        let settled = sung - state.window().lyric_start;
        ((settled * share::FPS as f64).max(0.0) as usize).min(frames - 1)
    }

    fn draw(&self, area: &gtk::DrawingArea, cr: &cairo::Context, width: i32, height: i32) {
        let scale = area.scale_factor().max(1);
        let pixels = width * scale;
        let mut state = self.state.borrow_mut();
        let frame = self.frame_index(&state);
        self.shown_frame.set(Some(frame));
        let rebuild = state.renderer.as_ref().is_none_or(|(_, built)| *built != pixels);
        if rebuild {
            let canvas = state.style.format.pixel_width() as f64;
            let renderer = Renderer::new(state.scene(), pixels as f64 / canvas);
            state.renderer = Some((renderer, pixels));
        }
        let Some((renderer, _)) = state.renderer.as_mut() else { return };
        let radius = 14.0;
        let (w, h) = (width as f64, height as f64);
        cr.new_sub_path();
        cr.arc(w - radius, radius, radius, -std::f64::consts::FRAC_PI_2, 0.0);
        cr.arc(w - radius, h - radius, radius, 0.0, std::f64::consts::FRAC_PI_2);
        cr.arc(radius, h - radius, radius, std::f64::consts::FRAC_PI_2, std::f64::consts::PI);
        cr.arc(radius, radius, radius, std::f64::consts::PI, 1.5 * std::f64::consts::PI);
        cr.close_path();
        cr.clip();
        cr.scale(1.0 / scale as f64, 1.0 / scale as f64);
        renderer.render(Some(frame), cr);
    }

    /// Asks where to save, then makes the video or the still card there off
    /// the main thread, showing progress for a video.
    fn save(self: &Rc<Self>, video: bool) {
        if self.state.borrow().export_cancel.is_some() {
            return;
        }
        self.pause_player();
        let name = {
            let state = self.state.borrow();
            share::file_name(&state.track.title, &state.track.artist, if video { "mp4" } else { "png" })
        };
        let folder = if video { dirs::video_dir() } else { dirs::picture_dir() }.or_else(dirs::home_dir);
        let chooser = gtk::FileDialog::builder()
            .title(if video { copy::SAVE_VIDEO } else { copy::SAVE_IMAGE })
            .initial_name(name.as_str())
            .build();
        if let Some(folder) = folder {
            chooser.set_initial_folder(Some(&gio::File::for_path(folder)));
        }
        let weak = Rc::downgrade(self);
        chooser.save(Some(&self.ui.window), None::<&gio::Cancellable>, move |result| {
            let Some(this) = weak.upgrade() else { return };
            let Ok(file) = result else { return };
            let Some(path) = file.path() else { return };
            this.export_to(path, video);
        });
    }

    fn export_to(self: &Rc<Self>, path: PathBuf, video: bool) {
        let cancel = Arc::new(AtomicBool::new(false));
        let (scene, audio) = {
            let mut state = self.state.borrow_mut();
            state.export_cancel = Some(Arc::clone(&cancel));
            (state.scene(), state.audio.clone())
        };
        self.set_exporting(video);
        let (progress_tx, progress_rx) = async_channel::unbounded::<f64>();
        let (done_tx, done_rx) = async_channel::bounded::<Result<(), ExportError>>(1);
        let target = path.clone();
        std::thread::spawn(move || {
            let result = if video {
                match audio {
                    Some(audio) => export::export_video(scene, &audio, &target, &cancel, |value| {
                        let _ = progress_tx.send_blocking(value);
                    }),
                    None => Err(ExportError::Unreadable("no audio".into())),
                }
            } else {
                export::export_image(scene, &target)
            };
            let _ = done_tx.send_blocking(result);
        });
        let progress = self.progress.clone();
        glib::spawn_future_local(async move {
            while let Ok(value) = progress_rx.recv().await {
                progress.set_fraction(value);
            }
        });
        let weak = Rc::downgrade(self);
        glib::spawn_future_local(async move {
            let Ok(result) = done_rx.recv().await else { return };
            let Some(this) = weak.upgrade() else { return };
            this.state.borrow_mut().export_cancel = None;
            this.set_exporting(false);
            let name = path.file_name().and_then(|name| name.to_str()).unwrap_or("the file").to_string();
            match result {
                Ok(()) => {
                    crate::logger::info("lyric_share", &format!("saved {}", path.display()));
                    this.ui.core.toast(&format!("Saved “{name}”"));
                }
                Err(ExportError::Cancelled) => {}
                Err(error) => {
                    crate::logger::error("lyric_share", &format!("export failed: {error:?}"));
                    this.ui.core.toast(&copy::export_failure(&error));
                }
            }
        });
    }

    fn set_exporting(&self, video: bool) {
        let exporting = self.state.borrow().export_cancel.is_some();
        self.progress_box.set_visible(exporting && video);
        self.buttons.set_visible(!(exporting && video));
        self.progress.set_fraction(0.0);
        self.show_audio_state();
    }

    fn teardown(&self) {
        if let Some(flag) = &self.state.borrow().export_cancel {
            flag.store(true, Ordering::Relaxed);
        }
        if let Some(source) = self.reload.borrow_mut().take() {
            source.remove();
        }
        self.stop_player();
        if self.paused_song.get() && !self.ui.core.player.is_playing() {
            self.ui.core.player.toggle_play_pause();
        }
        self.paused_song.set(false);
        if let Some(path) = self.state.borrow_mut().preview_path.take() {
            let _ = std::fs::remove_file(path);
        }
    }
}

/// A round chip of a theme's background with a dot of its ink.
fn draw_swatch(cr: &cairo::Context, palette: &Palette, width: f64, height: f64) {
    let radius = width.min(height) / 2.0 - 1.0;
    let (x, y) = (width / 2.0, height / 2.0);
    let gradient = cairo::LinearGradient::new(0.0, 0.0, 0.0, height);
    gradient.add_color_stop_rgb(0.0, palette.background.red, palette.background.green, palette.background.blue);
    gradient.add_color_stop_rgb(1.0, palette.background_deep.red, palette.background_deep.green, palette.background_deep.blue);
    cr.arc(x, y, radius, 0.0, 2.0 * std::f64::consts::PI);
    let _ = cr.set_source(&gradient);
    let _ = cr.fill_preserve();
    cr.set_source_rgba(0.5, 0.5, 0.5, 0.4);
    cr.set_line_width(1.0);
    let _ = cr.stroke();
    cr.set_source_rgb(palette.ink.red, palette.ink.green, palette.ink.blue);
    cr.arc(x, y, radius * 0.28, 0.0, 2.0 * std::f64::consts::PI);
    let _ = cr.fill();
}
