use crate::events::AppEvent;
use crate::musicvideo::comments::{self, Comment, Outcome, Sort};
use crate::musicvideo::{self, Phase, VideoMatch, VideoState};
use crate::ui::Ui;
use adw::prelude::*;
use gtk::gdk;
use gtk::glib;
use gtk::pango;
use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::rc::Rc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;

/// How long the panel waits after the video settles before asking YouTube, so
/// skipping through songs with the panel open asks nothing for the songs
/// skipped past.
const SETTLE: Duration = Duration::from_millis(600);
/// How long a comment stays lit after the video passes the moment it names.
const MOMENT_GLOW: f64 = 8.0;
/// How many lines of a comment show before it is opened.
const FOLDED_LINES: i32 = 7;
/// How many rows are built as the comments arrive, enough to fill the panel,
/// and how many at a time after that, between frames.
const FIRST_ROWS: usize = 12;
const ROW_BATCH: usize = 8;
const AVATAR_SIZE: i32 = 36;
/// Avatars kept in memory between songs; past this the oldest go.
const AVATARS_REMEMBERED: usize = 600;
/// The scheme of the links a comment's times become.
const SEEK_SCHEME: &str = "flaccy-seek:";

/// The music video's YouTube comments, beside the song they are about: top
/// or newest first, the uploader's own, pinned and hearted ones marked, and
/// every time a comment names ("1:29") a link that plays the song from that
/// moment of the video, lit while the song passes it. Moments lists only the
/// top comments that name a time, in the order the song reaches them. Asked
/// for only while the panel is open, and remembered per video.
pub struct CommentsPanel {
    pub widget: gtk::Widget,
    /// Opening the panel loads the playing video's comments; closing it
    /// stops it asking for any.
    pub set_active: Rc<dyn Fn(bool)>,
}

pub fn build(ui: &Rc<Ui>) -> CommentsPanel {
    let panel = Panel::new(ui);
    let set_active: Rc<dyn Fn(bool)> = {
        let panel = Rc::clone(&panel);
        Rc::new(move |active| {
            panel.active.set(active);
            if active {
                panel.refresh();
            } else {
                panel.cancel_pending();
            }
        })
    };
    {
        let weak = Rc::downgrade(&panel);
        ui.core.hub.subscribe_widget(&panel.root, move |_, event| {
            let Some(panel) = weak.upgrade() else { return };
            match event {
                AppEvent::MusicVideoChanged | AppEvent::TrackChanged(_) => panel.refresh(),
                AppEvent::Tick { position, .. } => panel.light_moments(*position),
                AppEvent::Seeked(position) => panel.light_moments(*position),
                _ => {}
            }
        });
    }
    CommentsPanel {
        widget: panel.root.clone().upcast(),
        set_active,
    }
}

/// What the panel lists: YouTube's own order, or the top comments that name
/// a moment of the video in the order the song reaches them.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum View {
    Sorted(Sort),
    Moments,
}

impl View {
    const ALL: [View; 3] = [View::Sorted(Sort::Top), View::Sorted(Sort::Newest), View::Moments];

    fn id(self) -> &'static str {
        match self {
            View::Sorted(sort) => sort.id(),
            View::Moments => "moments",
        }
    }

    fn from_id(id: &str) -> Self {
        Self::ALL
            .into_iter()
            .find(|view| view.id() == id)
            .unwrap_or(View::Sorted(Sort::Top))
    }

    fn label(self) -> &'static str {
        match self {
            View::Sorted(sort) => sort.label(),
            View::Moments => "Moments",
        }
    }

    /// The comments YouTube is asked for to fill this view.
    fn fetched(self) -> Sort {
        match self {
            View::Sorted(sort) => sort,
            View::Moments => Sort::Top,
        }
    }
}

/// A comment row and the moments of the video it names, in the video's
/// seconds.
struct Row {
    row: gtk::ListBoxRow,
    moments: Vec<f64>,
    lit: Cell<bool>,
}

struct Panel {
    ui: Rc<Ui>,
    root: gtk::Box,
    sort: adw::ToggleGroup,
    open: gtk::Button,
    source: gtk::Label,
    stack: gtk::Stack,
    waiting: gtk::Label,
    status: adw::StatusPage,
    status_button: gtk::Button,
    status_action: Cell<StatusAction>,
    scroll: gtk::ScrolledWindow,
    list: gtk::ListBox,
    active: Cell<bool>,
    /// The video and view whose comments are on screen.
    shown: RefCell<Option<(String, View)>>,
    /// The video and sort a fetch is under way or scheduled for.
    pending: RefCell<Option<(String, Sort)>>,
    settle: RefCell<Option<glib::SourceId>>,
    rows: RefCell<Vec<Row>>,
    /// Bumped whenever the rows are replaced, so an avatar download for rows
    /// that are gone stops.
    generation: Arc<AtomicU64>,
}

#[derive(Clone, Copy, PartialEq)]
enum StatusAction {
    None,
    ChooseVideo,
    RetryVideo,
    RetryComments,
    OpenOnYouTube,
}

impl Panel {
    fn new(ui: &Rc<Ui>) -> Rc<Self> {
        let sort = adw::ToggleGroup::new();
        sort.add_css_class("round");
        sort.add_css_class("np-comments-sort");
        for view in View::ALL {
            sort.add(adw::Toggle::builder().name(view.id()).label(view.label()).build());
        }
        sort.set_active_name(Some(
            View::from_id(&ui.core.config.borrow().np_comments_sort).id(),
        ));
        let open = gtk::Button::from_icon_name("web-browser-symbolic");
        open.add_css_class("flat");
        open.set_tooltip_text(Some("Open the Comments on YouTube"));
        open.set_valign(gtk::Align::Center);
        let header = gtk::Box::builder()
            .orientation(gtk::Orientation::Horizontal)
            .spacing(8)
            .margin_top(12)
            .margin_start(14)
            .margin_end(10)
            .build();
        let spacer = gtk::Box::new(gtk::Orientation::Horizontal, 0);
        spacer.set_hexpand(true);
        header.append(&sort);
        header.append(&spacer);
        header.append(&open);

        let source = gtk::Label::builder()
            .xalign(0.0)
            .wrap(true)
            .wrap_mode(pango::WrapMode::WordChar)
            .lines(2)
            .ellipsize(pango::EllipsizeMode::End)
            .margin_top(6)
            .margin_bottom(6)
            .margin_start(16)
            .margin_end(16)
            .build();
        source.add_css_class("dim");
        source.add_css_class("caption");

        let spinner = adw::Spinner::new();
        spinner.set_size_request(28, 28);
        let waiting = gtk::Label::new(Some("Loading comments…"));
        waiting.add_css_class("dim");
        let loading = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(12)
            .valign(gtk::Align::Center)
            .halign(gtk::Align::Center)
            .build();
        loading.append(&spinner);
        loading.append(&waiting);

        let status_button = gtk::Button::new();
        status_button.add_css_class("pill");
        status_button.set_halign(gtk::Align::Center);
        let status = adw::StatusPage::builder()
            .icon_name("flaccy-comments-symbolic")
            .child(&status_button)
            .build();
        status.add_css_class("compact");

        let list = gtk::ListBox::builder()
            .selection_mode(gtk::SelectionMode::None)
            .margin_top(8)
            .margin_bottom(12)
            .margin_start(8)
            .margin_end(8)
            .valign(gtk::Align::Start)
            .build();
        list.add_css_class("np-comments-list");
        let scroll = gtk::ScrolledWindow::builder()
            .hscrollbar_policy(gtk::PolicyType::Never)
            .vexpand(true)
            .child(&list)
            .build();

        let stack = gtk::Stack::builder()
            .transition_type(gtk::StackTransitionType::Crossfade)
            .transition_duration(160)
            .vexpand(true)
            .build();
        stack.add_named(&loading, Some("loading"));
        stack.add_named(&status, Some("status"));
        stack.add_named(&scroll, Some("list"));

        let root = gtk::Box::new(gtk::Orientation::Vertical, 0);
        root.add_css_class("np-comments");
        root.append(&header);
        root.append(&source);
        root.append(&stack);

        let panel = Rc::new(Self {
            ui: Rc::clone(ui),
            root,
            sort,
            open,
            source,
            stack,
            waiting,
            status,
            status_button,
            status_action: Cell::new(StatusAction::None),
            scroll,
            list,
            active: Cell::new(false),
            shown: RefCell::new(None),
            pending: RefCell::new(None),
            settle: RefCell::new(None),
            rows: RefCell::new(Vec::new()),
            generation: Arc::new(AtomicU64::new(0)),
        });
        panel.wire();
        panel
    }

    fn wire(self: &Rc<Self>) {
        {
            let weak = Rc::downgrade(self);
            self.sort.connect_active_name_notify(move |group| {
                let Some(panel) = weak.upgrade() else { return };
                let view = View::from_id(group.active_name().as_deref().unwrap_or_default());
                panel.ui.core.config.borrow_mut().np_comments_sort = view.id().to_string();
                panel.ui.core.save_config();
                panel.refresh();
            });
        }
        {
            let ui = Rc::clone(&self.ui);
            self.open.connect_clicked(move |_| open_comments_on_youtube(&ui));
        }
        {
            let weak = Rc::downgrade(self);
            self.status_button.connect_clicked(move |_| {
                let Some(panel) = weak.upgrade() else { return };
                let core = &panel.ui.core;
                match panel.status_action.get() {
                    StatusAction::None => {}
                    StatusAction::ChooseVideo => crate::ui::video_view::present_chooser(&panel.ui),
                    StatusAction::RetryVideo => musicvideo::retry(core),
                    StatusAction::RetryComments => {
                        panel.shown.replace(None);
                        panel.pending.replace(None);
                        panel.refresh();
                    }
                    StatusAction::OpenOnYouTube => open_comments_on_youtube(&panel.ui),
                }
            });
        }
    }

    fn view(&self) -> View {
        View::from_id(self.sort.active_name().as_deref().unwrap_or_default())
    }

    /// Brings the panel in line with the playing video: its comments when
    /// they are known, a fetch once the video settles when they are not, and
    /// a plain account of why there are none otherwise.
    fn refresh(self: &Rc<Self>) {
        if !self.active.get() {
            return;
        }
        let state = self.ui.core.music_video.state();
        let found = match &state {
            VideoState::Ready(found) => found.clone(),
            other => {
                self.cancel_pending();
                self.shown.replace(None);
                self.source.set_visible(false);
                self.open.set_sensitive(false);
                self.explain(other);
                return;
            }
        };
        self.open.set_sensitive(true);
        self.source.set_label(&source_line(&found));
        self.source.set_visible(true);
        let view = self.view();
        if self.shown.borrow().as_ref() == Some(&(found.video_id.clone(), view)) {
            return;
        }
        let want = (found.video_id.clone(), view.fetched());
        if let Some(outcome) = self.ui.core.music_video.comments.get(&want.0, want.1) {
            self.cancel_pending();
            self.show(&found, view, &outcome);
            return;
        }
        if self.pending.borrow().as_ref() == Some(&want) {
            return;
        }
        self.cancel_pending();
        self.show_waiting("Loading comments…");
        self.pending.replace(Some(want.clone()));
        let weak = Rc::downgrade(self);
        let source = glib::timeout_add_local_once(SETTLE, move || {
            let Some(panel) = weak.upgrade() else { return };
            panel.settle.borrow_mut().take();
            panel.fetch(want);
        });
        *self.settle.borrow_mut() = Some(source);
    }

    fn cancel_pending(&self) {
        if let Some(source) = self.settle.borrow_mut().take() {
            source.remove();
        }
        self.pending.replace(None);
    }

    /// Asks YouTube off the main thread, keeps the answer whatever happens to
    /// the panel meanwhile, and shows it if it is still the one wanted.
    fn fetch(self: &Rc<Self>, want: (String, Sort)) {
        let (tx, rx) = async_channel::bounded::<Outcome>(1);
        let (video_id, sort) = want.clone();
        crate::logger::info(
            "musicvideo",
            &format!("fetching {} comments for {video_id}", sort.label().to_lowercase()),
        );
        let spawned = std::thread::Builder::new()
            .name("flaccy-mv-comments".into())
            .spawn(move || {
                let _ = tx.send_blocking(comments::fetch(&video_id, sort));
            });
        if spawned.is_err() {
            self.pending.replace(None);
            return;
        }
        let weak = Rc::downgrade(self);
        glib::spawn_future_local(async move {
            let Ok(outcome) = rx.recv().await else { return };
            let Some(panel) = weak.upgrade() else { return };
            let (video_id, sort) = &want;
            match &outcome {
                Outcome::Loaded(list) => crate::logger::info(
                    "musicvideo",
                    &format!("{} comments for {video_id}", list.len()),
                ),
                Outcome::TurnedOff => crate::logger::info(
                    "musicvideo",
                    &format!("comments are turned off for {video_id}"),
                ),
                Outcome::Failed(reason) => crate::logger::warn(
                    "musicvideo",
                    &format!("comments for {video_id} failed: {reason}"),
                ),
            }
            panel
                .ui
                .core
                .music_video
                .comments
                .insert(video_id, *sort, outcome.clone());
            if panel.pending.borrow().as_ref() != Some(&want) {
                return;
            }
            panel.pending.replace(None);
            let found = panel.ui.core.music_video.state().matched().cloned();
            let view = panel.view();
            match found {
                Some(found) if &found.video_id == video_id && view.fetched() == *sort => {
                    panel.show(&found, view, &outcome)
                }
                _ => panel.refresh(),
            }
        });
    }

    fn show(self: &Rc<Self>, found: &VideoMatch, view: View, outcome: &Outcome) {
        self.shown.replace(Some((found.video_id.clone(), view)));
        match outcome {
            Outcome::Loaded(list) if list.is_empty() => self.show_status(
                "No Comments Yet",
                &format!("Nobody has commented on \u{201c}{}\u{201d} yet.", found.title),
                StatusAction::OpenOnYouTube,
            ),
            Outcome::Loaded(list) if view == View::Moments => {
                let named = in_song_order(list, found, self.song_duration());
                if named.is_empty() {
                    self.show_status(
                        "No Moments Named",
                        "None of the top comments on this video points at a moment of it, like \u{201c}2:05 this part\u{201d}.",
                        StatusAction::None,
                    );
                } else {
                    self.fill(found, &named);
                }
            }
            Outcome::Loaded(list) => self.fill(found, list),
            Outcome::TurnedOff => self.show_status(
                "Comments Are Off",
                &format!("{} turned comments off for this video.", channel_name(found)),
                StatusAction::OpenOnYouTube,
            ),
            Outcome::Failed(reason) => self.show_status(
                "Couldn\u{2019}t Load Comments",
                &format!(
                    "{}. Check your connection, then try again.",
                    crate::ui::video_view::brief(reason).trim_end_matches('.')
                ),
                StatusAction::RetryComments,
            ),
        }
    }

    /// What the panel says while there is no video to read comments from.
    fn explain(&self, state: &VideoState) {
        match state {
            VideoState::Searching(Phase::Loading) => self.show_waiting("Loading the music video…"),
            VideoState::Searching(_) => self.show_waiting("Finding the music video…"),
            VideoState::Missing(_) => self.show_status(
                "No Music Video",
                "Comments come from the song\u{2019}s music video on YouTube, and none was found for this song. Pick one if you know it.",
                StatusAction::ChooseVideo,
            ),
            VideoState::Failed(reason) => self.show_status(
                "No Music Video to Read",
                &format!(
                    "{}. The comments come from the music video; check your connection, then try again.",
                    crate::ui::video_view::brief(reason).trim_end_matches('.')
                ),
                StatusAction::RetryVideo,
            ),
            VideoState::Off if !musicvideo::available() => self.show_status(
                "Music Videos Are Unavailable",
                "Comments come from music videos, which need GStreamer\u{2019}s playbin3. Install gst-plugins-base and restart Flaccy.",
                StatusAction::None,
            ),
            VideoState::Off | VideoState::Ready(_) => self.show_status(
                "Nothing Playing",
                "Play a song and the comments on its music video show up here.",
                StatusAction::None,
            ),
        }
    }

    fn show_waiting(&self, text: &str) {
        self.waiting.set_label(text);
        self.stack.set_visible_child_name("loading");
    }

    fn show_status(&self, title: &str, description: &str, action: StatusAction) {
        self.status.set_title(title);
        self.status.set_description(Some(&glib::markup_escape_text(description)));
        self.status_action.set(action);
        let label = match action {
            StatusAction::None => None,
            StatusAction::ChooseVideo => Some("Choose a Video…"),
            StatusAction::RetryVideo | StatusAction::RetryComments => Some("Try Again"),
            StatusAction::OpenOnYouTube => Some("Open on YouTube"),
        };
        self.status_button.set_visible(label.is_some());
        if let Some(label) = label {
            self.status_button.set_label(label);
        }
        self.stack.set_visible_child_name("status");
    }

    /// Replaces the rows with `list` and scrolls back to the top. The first
    /// rows are built at once and the rest a few at a time between frames, so
    /// a hundred comments never hold the picture up; a newer set of rows stops
    /// the building, and the avatar downloads, for an older one.
    fn fill(self: &Rc<Self>, found: &VideoMatch, list: &[Comment]) {
        let started = std::time::Instant::now();
        let generation = self.generation.fetch_add(1, Ordering::Relaxed) + 1;
        self.list.remove_all();
        self.rows.replace(Vec::new());
        self.scroll.vadjustment().set_value(0.0);
        self.stack.set_visible_child_name("list");
        let duration = self.song_duration();
        let first = list.len().min(FIRST_ROWS);
        self.append_rows(found, &list[..first], duration, generation);
        crate::logger::info(
            "ui",
            &format!(
                "comments: first {first} of {} rows in {:.0} ms",
                list.len(),
                started.elapsed().as_secs_f64() * 1000.0
            ),
        );
        if let Some(position) = self.ui.core.player.position() {
            self.light_moments(position);
        }
        let rest: Vec<Comment> = list[first..].to_vec();
        if rest.is_empty() {
            return;
        }
        let mut rest = rest.into_iter();
        let weak = Rc::downgrade(self);
        let found = found.clone();
        glib::idle_add_local(move || {
            let Some(panel) = weak.upgrade() else {
                return glib::ControlFlow::Break;
            };
            if panel.generation.load(Ordering::Relaxed) != generation {
                return glib::ControlFlow::Break;
            }
            let batch: Vec<Comment> = rest.by_ref().take(ROW_BATCH).collect();
            if batch.is_empty() {
                return glib::ControlFlow::Break;
            }
            panel.append_rows(&found, &batch, duration, generation);
            glib::ControlFlow::Continue
        });
    }

    fn append_rows(&self, found: &VideoMatch, list: &[Comment], duration: f64, generation: u64) {
        let mut avatars: Vec<(String, adw::Avatar)> = Vec::new();
        let mut rows = self.rows.borrow_mut();
        for comment in list {
            let (row, avatar, moments) = comment_row(&self.ui, comment, found, duration);
            self.list.append(&row);
            if let Some(url) = &comment.avatar {
                avatars.push((url.clone(), avatar));
            }
            rows.push(Row {
                row,
                moments,
                lit: Cell::new(false),
            });
        }
        load_avatars(avatars, Arc::clone(&self.generation), generation);
    }

    fn song_duration(&self) -> f64 {
        self.ui
            .core
            .player
            .current_track()
            .map(|track| track.duration)
            .unwrap_or(0.0)
    }

    /// Lights the comments whose moment the video is passing.
    fn light_moments(&self, position: f64) {
        if !self.active.get() || self.shown.borrow().is_none() {
            return;
        }
        let rows = self.rows.borrow();
        if rows.iter().all(|row| row.moments.is_empty()) {
            return;
        }
        let Some(found) = self.ui.core.music_video.state().matched().cloned() else {
            return;
        };
        let video = found.video_time(position);
        for row in rows.iter() {
            let lit = row
                .moments
                .iter()
                .any(|moment| video >= *moment && video < moment + MOMENT_GLOW);
            if row.lit.replace(lit) != lit {
                if lit {
                    row.row.add_css_class("np-comment-now");
                } else {
                    row.row.remove_css_class("np-comment-now");
                }
            }
        }
    }
}

/// The comments that name a moment the song plays, ordered by the first
/// such moment.
fn in_song_order(list: &[Comment], found: &VideoMatch, duration: f64) -> Vec<Comment> {
    let mut named: Vec<(f64, &Comment)> = list
        .iter()
        .filter_map(|comment| {
            comments::moments(&comment.text)
                .into_iter()
                .filter_map(|moment| playable_at(found, moment.seconds, duration))
                .reduce(f64::min)
                .map(|local| (local, comment))
        })
        .collect();
    named.sort_by(|a, b| a.0.total_cmp(&b.0));
    named.into_iter().map(|(_, comment)| comment.clone()).collect()
}

/// Where in the song the video's `seconds` play, when they do.
fn playable_at(found: &VideoMatch, seconds: f64, duration: f64) -> Option<f64> {
    found
        .local_time(seconds)
        .filter(|local| duration <= 0.0 || *local < duration)
}

/// One comment: the author and their marks, the text with its times linked,
/// and what the video's audience made of it. Returns the row, the avatar to
/// fill in once its picture lands, and the moments of the video it names.
fn comment_row(
    ui: &Rc<Ui>,
    comment: &Comment,
    found: &VideoMatch,
    duration: f64,
) -> (gtk::ListBoxRow, adw::Avatar, Vec<f64>) {
    let name = comment.author.trim_start_matches('@');
    let avatar = adw::Avatar::new(AVATAR_SIZE, Some(name), true);
    avatar.set_valign(gtk::Align::Start);

    let author = gtk::Label::builder()
        .label(&comment.author)
        .xalign(0.0)
        .ellipsize(pango::EllipsizeMode::End)
        .build();
    author.add_css_class("np-comment-author");
    if comment.by_uploader {
        author.add_css_class("np-comment-uploader");
    }
    let head = gtk::Box::new(gtk::Orientation::Horizontal, 6);
    head.append(&author);
    if comment.verified {
        let check = gtk::Image::from_icon_name("emblem-ok-symbolic");
        check.set_pixel_size(12);
        check.add_css_class("dim");
        check.set_tooltip_text(Some("Verified"));
        head.append(&check);
    }
    let age = if comment.edited {
        format!("{} (edited)", comment.age)
    } else {
        comment.age.clone()
    };
    if !age.is_empty() {
        let when = gtk::Label::builder()
            .label(&age)
            .xalign(0.0)
            .ellipsize(pango::EllipsizeMode::End)
            .build();
        when.add_css_class("dim");
        when.add_css_class("caption");
        head.append(&when);
    }

    let mut moments = Vec::new();
    let marked: Vec<(comments::Moment, Option<f64>)> = comments::moments(&comment.text)
        .into_iter()
        .map(|moment| {
            let local = playable_at(found, moment.seconds, duration);
            if local.is_some() {
                moments.push(moment.seconds);
            }
            (moment, local)
        })
        .collect();
    let text = gtk::Label::builder()
        .use_markup(true)
        .label(linked_markup(&comment.text, &marked))
        .xalign(0.0)
        .wrap(true)
        .wrap_mode(pango::WrapMode::WordChar)
        .lines(FOLDED_LINES)
        .ellipsize(pango::EllipsizeMode::End)
        .build();
    text.add_css_class("np-comment-text");
    {
        let ui = Rc::clone(ui);
        text.connect_activate_link(move |_, uri| match uri.strip_prefix(SEEK_SCHEME) {
            Some(seconds) => {
                if let Ok(seconds) = seconds.parse::<f64>() {
                    crate::logger::info("ui", &format!("comments: play from {seconds:.1}s"));
                    ui.core.player.seek(seconds);
                }
                glib::Propagation::Stop
            }
            None => glib::Propagation::Proceed,
        });
    }

    let foot = gtk::Box::new(gtk::Orientation::Horizontal, 14);
    foot.add_css_class("np-comment-foot");
    if comment.likes > 0 {
        let likes = gtk::Box::new(gtk::Orientation::Horizontal, 5);
        let thumb = gtk::Image::from_icon_name("flaccy-thumb-up-symbolic");
        thumb.set_pixel_size(12);
        likes.append(&thumb);
        likes.append(&gtk::Label::new(Some(&crate::ui::video_view::compact_count(
            comment.likes,
        ))));
        likes.set_tooltip_text(Some(&format!("{} likes", comment.likes)));
        foot.append(&likes);
    }
    if comment.hearted {
        let hearted = gtk::Box::new(gtk::Orientation::Horizontal, 5);
        hearted.add_css_class("np-comment-hearted");
        let heart = gtk::Image::from_icon_name("emote-love-symbolic");
        heart.set_pixel_size(12);
        hearted.append(&heart);
        hearted.append(&gtk::Label::new(Some(&format!("by {}", channel_name(found)))));
        foot.append(&hearted);
    }

    let body = gtk::Box::new(gtk::Orientation::Vertical, 4);
    body.set_hexpand(true);
    if comment.pinned {
        let pinned = gtk::Box::new(gtk::Orientation::Horizontal, 5);
        pinned.add_css_class("dim");
        pinned.add_css_class("caption");
        let pin = gtk::Image::from_icon_name("view-pin-symbolic");
        pin.set_pixel_size(12);
        pinned.append(&pin);
        pinned.append(&gtk::Label::new(Some(&format!("Pinned by {}", channel_name(found)))));
        body.append(&pinned);
    }
    body.append(&head);
    body.append(&text);
    if foot.first_child().is_some() {
        body.append(&foot);
    }

    let content = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(12)
        .margin_top(10)
        .margin_bottom(10)
        .margin_start(8)
        .margin_end(8)
        .build();
    content.append(&avatar);
    content.append(&body);
    fold_on_click(&text, &content);
    let row = gtk::ListBoxRow::builder()
        .child(&content)
        .activatable(false)
        .build();
    row.add_css_class("np-comment");
    if comment.by_uploader || comment.pinned {
        row.add_css_class("np-comment-featured");
    }
    row.update_property(&[gtk::accessible::Property::Label(&format!(
        "{}: {}",
        name, comment.text
    ))]);
    (row, avatar, moments)
}

/// A folded comment opens to its full length when it is clicked anywhere
/// but on a link, and folds again on the next click.
fn fold_on_click(text: &gtk::Label, area: &gtk::Box) {
    let click = gtk::GestureClick::new();
    let text = text.downgrade();
    click.connect_released(move |gesture, presses, _, _| {
        let Some(text) = text.upgrade() else { return };
        if presses != 1 || text.current_uri().is_some() {
            return;
        }
        gesture.set_state(gtk::EventSequenceState::Claimed);
        let folded = text.lines() > 0;
        text.set_lines(if folded { -1 } else { FOLDED_LINES });
        text.set_ellipsize(if folded {
            pango::EllipsizeMode::None
        } else {
            pango::EllipsizeMode::End
        });
    });
    area.add_controller(click);
}

/// The comment as Pango markup: everything escaped, each time the song can
/// play from turned into a seek link to that place in the local file, and web
/// addresses into links that open in the browser.
fn linked_markup(text: &str, moments: &[(comments::Moment, Option<f64>)]) -> String {
    let mut markup = String::with_capacity(text.len() + 32);
    let mut cursor = 0;
    let mut spans: Vec<(std::ops::Range<usize>, String)> = moments
        .iter()
        .filter_map(|(moment, local)| {
            local.map(|local| (moment.range.clone(), format!("{SEEK_SCHEME}{local:.2}")))
        })
        .collect();
    spans.extend(web_links(text));
    spans.sort_by_key(|(range, _)| range.start);
    for (range, href) in spans {
        if range.start < cursor {
            continue;
        }
        markup.push_str(&glib::markup_escape_text(&text[cursor..range.start]));
        markup.push_str(&format!(
            "<a href=\"{}\">{}</a>",
            glib::markup_escape_text(&href),
            glib::markup_escape_text(&text[range.clone()])
        ));
        cursor = range.end;
    }
    markup.push_str(&glib::markup_escape_text(&text[cursor..]));
    markup
}

/// The http(s) addresses in a comment, each running to the next space, less
/// any closing punctuation the sentence put after it.
fn web_links(text: &str) -> Vec<(std::ops::Range<usize>, String)> {
    let mut links = Vec::new();
    let mut from = 0;
    while let Some(found) = ["https://", "http://"]
        .iter()
        .filter_map(|scheme| text[from..].find(scheme).map(|at| from + at))
        .min()
    {
        let rest = &text[found..];
        let length = rest.find(char::is_whitespace).unwrap_or(rest.len());
        let link = rest[..length].trim_end_matches(['.', ',', ')', '!', '?', ';', ':', '"', '\'']);
        if link.len() > "https://".len() {
            links.push((found..found + link.len(), link.to_string()));
        }
        from = found + length.max(1);
    }
    links
}

/// Which video the comments are under, so a wrong match is noticed.
fn source_line(found: &VideoMatch) -> String {
    if found.channel.is_empty() {
        format!("On \u{201c}{}\u{201d}", found.title)
    } else {
        format!("On \u{201c}{}\u{201d} \u{b7} {}", found.title, found.channel)
    }
}

fn channel_name(found: &VideoMatch) -> String {
    if found.channel.is_empty() {
        "The uploader".to_string()
    } else {
        found.channel.clone()
    }
}

/// Opens the playing video on YouTube at its comments.
fn open_comments_on_youtube(ui: &Rc<Ui>) {
    let Some(found) = ui.core.music_video.state().matched().cloned() else {
        return;
    };
    let url = format!("{}#comments", musicvideo::search::watch_url(&found.video_id));
    let launcher = gtk::UriLauncher::new(&url);
    let ui = Rc::clone(ui);
    launcher.launch(
        Some(&ui.window.clone()),
        gtk::gio::Cancellable::NONE,
        move |result| {
            if let Err(err) = result {
                ui.core.toast(&format!("Couldn\u{2019}t open YouTube: {err}"));
            }
        },
    );
}

thread_local! {
    static AVATARS: RefCell<HashMap<String, gdk::Texture>> = RefCell::new(HashMap::new());
}

/// Fills in each avatar from memory, or downloads it off the main thread in
/// the order the rows are shown; a newer set of rows stops the downloads for
/// an older one.
fn load_avatars(wanted: Vec<(String, adw::Avatar)>, generation: Arc<AtomicU64>, mine: u64) {
    let mut missing: Vec<String> = Vec::new();
    let mut waiting: HashMap<String, Vec<adw::Avatar>> = HashMap::new();
    for (url, avatar) in wanted {
        let cached = AVATARS.with(|avatars| avatars.borrow().get(&url).cloned());
        match cached {
            Some(texture) => avatar.set_custom_image(Some(&texture)),
            None => {
                if !waiting.contains_key(&url) {
                    missing.push(url.clone());
                }
                waiting.entry(url).or_default().push(avatar);
            }
        }
    }
    if missing.is_empty() {
        return;
    }
    let (tx, rx) = async_channel::unbounded::<(String, Vec<u8>)>();
    std::thread::Builder::new()
        .name("flaccy-mv-avatars".into())
        .spawn(move || {
            let agent = ureq::AgentBuilder::new()
                .timeout(Duration::from_secs(8))
                .build();
            for url in missing {
                if generation.load(Ordering::Relaxed) != mine {
                    return;
                }
                let Ok(response) = agent.get(&url).call() else {
                    continue;
                };
                let mut bytes = Vec::new();
                if std::io::Read::read_to_end(&mut response.into_reader(), &mut bytes).is_ok()
                    && tx.send_blocking((url, bytes)).is_err()
                {
                    return;
                }
            }
        })
        .ok();
    glib::spawn_future_local(async move {
        while let Ok((url, bytes)) = rx.recv().await {
            let Ok(texture) = gdk::Texture::from_bytes(&glib::Bytes::from_owned(bytes)) else {
                continue;
            };
            AVATARS.with(|avatars| {
                let mut avatars = avatars.borrow_mut();
                if avatars.len() >= AVATARS_REMEMBERED {
                    avatars.clear();
                }
                avatars.insert(url.clone(), texture.clone());
            });
            for avatar in waiting.remove(&url).unwrap_or_default() {
                avatar.set_custom_image(Some(&texture));
            }
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    fn moment(text: &str, local: Option<f64>) -> Vec<(comments::Moment, Option<f64>)> {
        comments::moments(text)
            .into_iter()
            .map(|moment| (moment, local))
            .collect()
    }

    #[test]
    fn a_time_the_song_can_play_from_becomes_a_seek_link() {
        let text = "the flip at 1:29 <3";
        let markup = linked_markup(text, &moment(text, Some(81.5)));
        assert_eq!(
            markup,
            "the flip at <a href=\"flaccy-seek:81.50\">1:29</a> &lt;3"
        );
    }

    #[test]
    fn a_time_the_album_does_not_have_stays_plain_text() {
        let text = "intro skit at 0:12";
        assert_eq!(linked_markup(text, &moment(text, None)), text);
    }

    #[test]
    fn web_addresses_become_links_without_their_full_stop() {
        let text = "see https://example.com/a?b=1&c=2. & 2:00";
        let markup = linked_markup(text, &moment(text, Some(110.0)));
        assert_eq!(
            markup,
            "see <a href=\"https://example.com/a?b=1&amp;c=2\">https://example.com/a?b=1&amp;c=2</a>. &amp; <a href=\"flaccy-seek:110.00\">2:00</a>"
        );
    }

    fn found(offset: f64) -> VideoMatch {
        VideoMatch {
            video_id: "v".into(),
            title: String::new(),
            channel: String::new(),
            duration: 240.0,
            offset,
            aligned: true,
            chosen_by_user: false,
            reason: String::new(),
            map: flaccy_library::music_video::TimeMap::default(),
            trim: 0.0,
            align_version: 0,
        }
    }

    fn comment(text: &str) -> Comment {
        Comment {
            id: text.into(),
            author: "@a".into(),
            avatar: None,
            text: text.into(),
            likes: 0,
            age: String::new(),
            edited: false,
            pinned: false,
            by_uploader: false,
            hearted: false,
            verified: false,
        }
    }

    #[test]
    fn moments_come_in_the_order_the_song_reaches_them() {
        let list = vec![
            comment("2:05 this part"),
            comment("no time here"),
            comment("0:54 and again at 0:40"),
            comment("9:59 past the end"),
            comment("0:05 before the song starts"),
        ];
        let named = in_song_order(&list, &found(10.0), 200.0);
        let texts: Vec<&str> = named.iter().map(|comment| comment.text.as_str()).collect();
        assert_eq!(texts, ["0:54 and again at 0:40", "2:05 this part"]);
    }

    #[test]
    fn view_ids_round_trip() {
        for view in View::ALL {
            assert_eq!(View::from_id(view.id()), view);
        }
        assert_eq!(View::from_id("bogus"), View::Sorted(Sort::Top));
    }

    #[test]
    fn a_bare_scheme_is_not_a_link() {
        assert!(web_links("https:// nothing").is_empty());
        assert_eq!(web_links("(http://a.io)").len(), 1);
    }
}
