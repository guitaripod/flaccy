use crate::events::AppEvent;
use crate::load_progress::{group_digits, LoadProgress};
use crate::ui::{FrameDriver, Ui};
use adw::prelude::*;
use flaccy_shared::enrichment_job::{copy as job_copy, JobProgress};
use flaccy_shared::library_debut::{copy as debut_copy, DebutAct, DebutDirector, DebutSummary};
use flaccy_shared::library_surface::{Surface, SurfaceRouter};
use gtk::glib::BoxedAnyObject;
use gtk::{cairo, gdk, gio, glib};
use std::cell::{Cell, RefCell};
use std::collections::{HashMap, HashSet, VecDeque};
use std::rc::Rc;
use std::time::{Duration, Instant};

/// The Apple clients' tile spring, to the number: `RESPONSE` is the period of a
/// full oscillation in seconds and `DAMPING` the fraction of critical damping,
/// so a tile lands in the same 0.42 s with the same slight overshoot on GNOME
/// as it does on iPhone.
const SPRING_RESPONSE: f64 = 0.42;
const SPRING_DAMPING: f64 = 0.72;
/// Where a tile starts its entry, before the spring carries it to 1.0.
const TILE_ENTRY_SCALE: f64 = 0.86;
/// How far the four neighbours of a filling tile are shoved outward, in pixels,
/// before their own springs pull them back.
const NEIGHBOUR_NUDGE: f64 = 2.0;
/// One crossfade — gradient to cover, or old cover to new — in seconds.
const CROSSFADE_SECONDS: f64 = 0.35;
/// The mosaic grows 4×4 → 5×5 → 6×6 and stops; past this the oldest tile is
/// recycled, so a three-thousand-album library keeps living without the grid
/// turning into a wall of thumbnails.
const MAX_TILES: usize = 36;
/// The grid the page opens on, before a single tag has been read.
const OPENING_TILES: usize = 16;
const TILE_SIZE: i32 = 72;
const TILE_RADIUS: f64 = 10.0;
/// How often the mosaic takes one more album off the queue while it is still
/// filling. Twenty of these is the ~900 ms recycle beat once it is full.
const PUMP_INTERVAL: Duration = Duration::from_millis(45);
const PUMP_TICKS_PER_ROTATION: u32 = 20;
/// Act II dims the mosaic so a tile the job has just repaired can come back to
/// full strength on its own.
const ACT_II_DIM: f64 = 0.55;
/// Act III's one choreographed settle: every tile drops in from six pixels up,
/// twelve milliseconds apart.
const ACT_III_LIFT: f64 = 6.0;
const ACT_III_STAGGER: f64 = 0.012;
const COVER_REQUEST_SIZE: u32 = 96;

/// Stages the once-per-library Debut as a third page of the albums stack.
///
/// The gate is read exactly once, here, at startup. `AppCore::record_library_debut`
/// writes the `libraryDebut` row the moment the first build yields an album —
/// while the show is still running — so a client that re-read the row mid-launch
/// would pull its own curtain down halfway through. Every later launch finds the
/// row and adds nothing to the hierarchy at all: no page, no mosaic, no frame
/// clock, no summary card, ever again. The row's *figures* are not read back
/// here: `present_summary` recomputes them at Act III and `finish` writes what
/// the reader actually saw over the build-time floor.
pub fn install(
    ui: &Rc<Ui>,
    stack: &gtk::Stack,
    presenting: &Rc<Cell<bool>>,
    rebuild: &Rc<dyn Fn()>,
) {
    if ui.core.db.library_debut().is_some() {
        return;
    }
    let mosaic = Mosaic::new();
    let (page, widgets) = build_page(&mosaic);
    stack.add_named(&page, Some("debut"));

    let stage = Rc::new(Stage {
        ui: Rc::clone(ui),
        page: page.downgrade(),
        stack: stack.downgrade(),
        presenting: Rc::clone(presenting),
        rebuild: Rc::clone(rebuild),
        router: Cell::new(SurfaceRouter::new()),
        director: Cell::new(DebutDirector::new()),
        load: Cell::new(LoadProgress::default()),
        job: RefCell::new(ui.core.job_progress()),
        scan_settled: Cell::new(false),
        job_primed: Cell::new(false),
        finished: Cell::new(false),
        finishing_since: Cell::new(None),
        curtain_ticking: Cell::new(false),
        presented_summary: RefCell::new(None),
        mosaic,
        widgets,
    });
    {
        let stage = Rc::clone(&stage);
        ui.core
            .hub
            .subscribe_widget(&page, move |_, event| stage.on_event(event));
    }
    stage.sync();
}

struct Widgets {
    headline: gtk::Label,
    explanation: gtk::Label,
    status: gtk::Stack,
    progress: gtk::ProgressBar,
    countdown: gtk::Label,
    files: gtk::Label,
    tracks: gtk::Label,
    albums: gtk::Label,
}

struct Stage {
    ui: Rc<Ui>,
    /// Weak on purpose: the hub subscription is pruned by the page's death, and
    /// a stage that held its own page alive would keep that subscription — and
    /// itself — forever.
    page: glib::WeakRef<gtk::Box>,
    stack: glib::WeakRef<gtk::Stack>,
    presenting: Rc<Cell<bool>>,
    rebuild: Rc<dyn Fn()>,
    router: Cell<SurfaceRouter>,
    director: Cell<DebutDirector>,
    load: Cell<LoadProgress>,
    job: RefCell<JobProgress>,
    scan_settled: Cell<bool>,
    job_primed: Cell<bool>,
    finished: Cell<bool>,
    finishing_since: Cell<Option<Instant>>,
    curtain_ticking: Cell<bool>,
    /// The figures the card actually showed, held until dismissal so the row
    /// that survives the Debut is the one the reader read.
    presented_summary: RefCell<Option<DebutSummary>>,
    mosaic: Rc<Mosaic>,
    widgets: Widgets,
}

impl Stage {
    fn on_event(self: &Rc<Self>, event: &AppEvent) {
        match event {
            AppEvent::ScanProgress(load) => {
                self.load.set(*load);
                self.mosaic.ensure_slots(slots_for(load));
            }
            AppEvent::EnrichmentProgress(job) => *self.job.borrow_mut() = job.clone(),
            AppEvent::ScanFinished { .. } => self.scan_settled.set(true),
            AppEvent::LibraryReloaded => self.mosaic.enqueue_library(&self.ui),
            AppEvent::AlbumCoversHoisted(covers) => self.mosaic.enqueue_hoisted(&self.ui, covers),
            AppEvent::AlbumEnriched { title, artist } => {
                self.mosaic.repaired(&self.ui, title, artist)
            }
            _ => return,
        }
        self.sync();
    }

    /// One routing decision and one act advance per event, in that order: the
    /// router says whether the Debut holds the page at all, and only then does
    /// the director get to move the act forward.
    fn sync(self: &Rc<Self>) {
        if self.finished.get() {
            return;
        }
        let load = self.load.get();
        let job = self.job.borrow().clone();
        let album_count = self.ui.core.library.borrow().albums.len();
        let mut router = self.router.get();
        let surface = router.route(
            &load,
            &job,
            false,
            album_count > 0,
            self.job_elapsed(&job),
        );
        self.router.set(router);

        let wanted = surface == Surface::Debut;
        if self.presenting.replace(wanted) != wanted {
            (self.rebuild)();
        }
        if !wanted {
            return;
        }
        if !self.ready_to_advance(&load) {
            self.render(&load, &job);
            return;
        }

        let mut director = self.director.get();
        let advanced = director.advance(&load, &job, album_count, self.finishing_elapsed());
        let act = director.act();
        self.director.set(director);
        if advanced {
            self.enter(act);
        }
        self.render(&load, &job);
    }

    /// Two things have to be true before the act may leave Act I, and neither is
    /// visible to the shared director. The Linux client reads its database into
    /// an empty library *before* it scans the disk, so an unguarded director
    /// would see "no phase blocking, no albums" and call the whole thing done
    /// before the first file was found; and the countdown starts life idle, so
    /// an unprimed job would drain Act II the instant it began. The first miss
    /// waits for `ScanFinished`, the second re-reads the countdown from the
    /// database once and lets the resulting event drive the advance.
    fn ready_to_advance(self: &Rc<Self>, load: &LoadProgress) -> bool {
        if !self.scan_settled.get() {
            return false;
        }
        if load.phase.blocks_library() || self.job_primed.replace(true) {
            return true;
        }
        let core = Rc::downgrade(&self.ui.core);
        glib::idle_add_local_once(move || {
            if let Some(core) = core.upgrade() {
                core.refresh_job_progress();
            }
        });
        false
    }

    fn enter(self: &Rc<Self>, act: DebutAct) {
        match act {
            DebutAct::Finishing => {
                self.finishing_since.set(Some(Instant::now()));
                self.mosaic.dim(ACT_II_DIM);
                self.start_curtain();
            }
            DebutAct::Summary => {
                self.mosaic.settle();
                self.present_summary();
            }
            DebutAct::Done => self.finish(),
            DebutAct::Indexing => {}
        }
    }

    /// The curtain budget is a wall-clock deadline, so it needs a clock of its
    /// own: a job that stops publishing must not be able to hold a new user's
    /// library hostage just by going quiet.
    fn start_curtain(self: &Rc<Self>) {
        if self.curtain_ticking.replace(true) {
            return;
        }
        let weak = Rc::downgrade(self);
        glib::timeout_add_local(Duration::from_secs(1), move || {
            let Some(stage) = weak.upgrade() else {
                return glib::ControlFlow::Break;
            };
            if stage.finished.get() || stage.director.get().act() >= DebutAct::Summary {
                stage.curtain_ticking.set(false);
                return glib::ControlFlow::Break;
            }
            stage.sync();
            glib::ControlFlow::Continue
        });
    }

    fn render(&self, load: &LoadProgress, job: &JobProgress) {
        let widgets = &self.widgets;
        widgets
            .files
            .set_label(&group_digits(load.files_found.max(load.total)));
        widgets.tracks.set_label(&group_digits(load.tracks_indexed));
        widgets.albums.set_label(&group_digits(
            self.ui.core.library.borrow().albums.len().max(load.albums_built),
        ));

        if self.director.get().act() == DebutAct::Indexing {
            widgets.headline.set_label(load.phase.headline());
            widgets.explanation.set_label(load.phase.explanation());
            if load.is_determinate() {
                widgets.progress.set_fraction(load.fraction_completed());
            } else {
                widgets.progress.pulse();
            }
            widgets.status.set_visible_child_name("bar");
            return;
        }
        widgets.headline.set_label(debut_copy::ARTWORK_HEADLINE);
        widgets
            .explanation
            .set_label(debut_copy::ARTWORK_EXPLANATION);
        widgets
            .countdown
            .set_label(&job_copy::ambient(job).unwrap_or_default());
        widgets.status.set_visible_child_name("countdown");
    }

    /// The summary card rises over the mosaic rather than replacing it — the
    /// library the reader watched being built is still moving underneath.
    ///
    /// The figures are computed here, at Act III, the way iOS recomputes them
    /// on entry: the build-time row was written before the job ran, so reading
    /// it back would report a cover and date tally that Act II has since moved.
    fn present_summary(self: &Rc<Self>) {
        let summary = self.ui.core.current_debut_summary();
        *self.presented_summary.borrow_mut() = Some(summary.clone());
        let (content, primary) = build_summary_card(&summary);
        let dialog = adw::Dialog::builder()
            .content_width(440)
            .child(&content)
            .build();
        {
            let dialog = dialog.clone();
            primary.connect_clicked(move |_| {
                dialog.close();
            });
        }
        {
            let stage = Rc::clone(self);
            dialog.connect_closed(move |_| stage.finish());
        }
        dialog.present(Some(&self.ui.window));
    }

    /// Hands the page back to the album grid for good. Whatever the job had not
    /// finished carries on silently on the header's ambient line.
    fn finish(self: &Rc<Self>) {
        if self.finished.replace(true) {
            return;
        }
        self.persist_presented_summary();
        let mut router = self.router.get();
        router.release_debut();
        self.router.set(router);
        self.presenting.set(false);
        (self.rebuild)();
        self.mosaic.retire();
        if let (Some(stack), Some(page)) = (self.stack.upgrade(), self.page.upgrade()) {
            stack.remove(&page);
        }
        crate::logger::info("library", "library debut finished");
    }

    /// Writes the card's own figures over the build-time row, mirroring iOS's
    /// `completeDebut(with:)` from `onDismiss`. A Debut that ended without ever
    /// raising a card — an album-less build going straight to `Done` — leaves
    /// the row exactly as the build wrote it.
    fn persist_presented_summary(&self) {
        let Some(summary) = self.presented_summary.borrow().clone() else {
            return;
        };
        if let Err(err) = self.ui.core.db.save_library_debut(&summary) {
            crate::logger::error("database", &format!("libraryDebut update failed: {err}"));
        }
    }

    fn job_elapsed(&self, job: &JobProgress) -> f64 {
        job.started_at
            .map(|started| (chrono::Utc::now() - started).num_milliseconds() as f64 / 1000.0)
            .unwrap_or(0.0)
    }

    fn finishing_elapsed(&self) -> f64 {
        self.finishing_since
            .get()
            .map(|since| since.elapsed().as_secs_f64())
            .unwrap_or(0.0)
    }
}

/// How many slots the mosaic should be showing for a scan that has read this
/// much. It opens as a full 4×4 of gradients so the page is never blank, then
/// grows one slot per indexed track — the picture grows with the work instead
/// of appearing all at once at the end.
fn slots_for(load: &LoadProgress) -> usize {
    load.tracks_indexed
        .max(load.completed)
        .max(OPENING_TILES)
        .min(MAX_TILES)
}

fn build_page(mosaic: &Rc<Mosaic>) -> (gtk::Box, Widgets) {
    let wordmark = gtk::Label::new(Some("flaccy"));
    wordmark.add_css_class("caption");
    wordmark.set_opacity(0.4);

    let headline = gtk::Label::builder()
        .justify(gtk::Justification::Center)
        .wrap(true)
        .build();
    headline.add_css_class("title-2");
    let explanation = gtk::Label::builder()
        .justify(gtk::Justification::Center)
        .wrap(true)
        .max_width_chars(46)
        .build();
    explanation.add_css_class("dim");

    let progress = gtk::ProgressBar::builder().width_request(320).build();
    progress.set_valign(gtk::Align::Center);
    let countdown = gtk::Label::new(None);
    countdown.add_css_class("caption");
    countdown.add_css_class("dim");

    let status = gtk::Stack::builder()
        .transition_type(gtk::StackTransitionType::Crossfade)
        .halign(gtk::Align::Center)
        .build();
    status.add_named(&progress, Some("bar"));
    status.add_named(&countdown, Some("countdown"));

    let (files_tile, files) = tally_tile("Files");
    let (tracks_tile, tracks) = tally_tile(debut_copy::STAT_TRACKS);
    let (albums_tile, albums) = tally_tile(debut_copy::STAT_ALBUMS);
    let tallies = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(10)
        .homogeneous(true)
        .halign(gtk::Align::Center)
        .build();
    tallies.append(&files_tile);
    tallies.append(&tracks_tile);
    tallies.append(&albums_tile);

    let page = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(18)
        .halign(gtk::Align::Center)
        .valign(gtk::Align::Center)
        .margin_top(32)
        .margin_bottom(32)
        .margin_start(24)
        .margin_end(24)
        .build();
    page.append(&wordmark);
    page.append(&mosaic.holder);
    page.append(&headline);
    page.append(&explanation);
    page.append(&tallies);
    page.append(&status);

    (
        page,
        Widgets {
            headline,
            explanation,
            status,
            progress,
            countdown,
            files,
            tracks,
            albums,
        },
    )
}

/// One count under a letterspaced caption; returns the value label so the tally
/// can be rewritten on every snapshot without rebuilding the row.
fn tally_tile(caption: &str) -> (gtk::Box, gtk::Label) {
    let tile = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(2)
        .build();
    tile.add_css_class("stat-tile");
    let value = gtk::Label::builder().label("0").xalign(0.0).build();
    value.add_css_class("stat-value");
    let caption_label = gtk::Label::builder().label(caption).xalign(0.0).build();
    caption_label.add_css_class("stat-caption");
    tile.append(&value);
    tile.append(&caption_label);
    (tile, value)
}

/// Act III's card. The paywall line, the AI tally and the secondary "See what's
/// included" are deliberately absent here: the Linux client is GPL, ships no
/// purchase, and never calls Groq, so all three would be reporting something
/// that does not exist on this platform.
fn build_summary_card(summary: &DebutSummary) -> (gtk::Widget, gtk::Button) {
    let content = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(18)
        .margin_top(28)
        .margin_bottom(28)
        .margin_start(28)
        .margin_end(28)
        .build();

    let title = gtk::Label::builder()
        .label(debut_copy::CARD_TITLE)
        .xalign(0.0)
        .wrap(true)
        .build();
    title.add_css_class("title-1");
    content.append(&title);

    let stats = gtk::Grid::builder()
        .row_spacing(10)
        .column_spacing(10)
        .column_homogeneous(true)
        .build();
    let cells = [
        (
            group_digits(summary.track_count),
            debut_copy::STAT_TRACKS,
        ),
        (
            group_digits(summary.album_count),
            debut_copy::STAT_ALBUMS,
        ),
        (
            group_digits(summary.artist_count),
            debut_copy::STAT_ARTISTS,
        ),
        (
            format_library_duration(summary.total_duration_seconds),
            debut_copy::STAT_DURATION,
        ),
    ];
    for (index, (value, caption)) in cells.iter().enumerate() {
        let (tile, label) = tally_tile(caption);
        label.set_label(value);
        stats.attach(&tile, (index % 2) as i32, (index / 2) as i32, 1, 1);
    }
    content.append(&stats);

    for line in [
        debut_copy::card_line_covers(summary.covers_resolved, summary.albums_dated),
        debut_copy::card_line_quality(
            lossless_percent(summary),
            summary.average_bitrate,
        ),
    ] {
        let label = gtk::Label::builder()
            .label(line.as_str())
            .xalign(0.0)
            .wrap(true)
            .build();
        label.add_css_class("dim");
        content.append(&label);
    }

    let primary = gtk::Button::with_label(debut_copy::CARD_PRIMARY);
    primary.add_css_class("pill");
    primary.add_css_class("suggested-action");
    content.append(&primary);

    (content.upcast(), primary)
}

fn lossless_percent(summary: &DebutSummary) -> usize {
    if summary.track_count == 0 {
        return 0;
    }
    summary.lossless_track_count * 100 / summary.track_count
}

/// The card's "Of music" value: days and hours for a real library, hours and
/// minutes for a small one, minutes for a handful of tracks. Whole units only —
/// nobody reads seconds at library scale.
fn format_library_duration(seconds: f64) -> String {
    let total = seconds.max(0.0).round() as u64;
    let days = total / 86_400;
    let hours = (total % 86_400) / 3_600;
    let minutes = (total % 3_600) / 60;
    if days > 0 {
        return format!("{} {}", unit(days, "day", "days"), unit(hours, "hour", "hours"));
    }
    if hours > 0 {
        return format!(
            "{} {}",
            unit(hours, "hour", "hours"),
            unit(minutes, "minute", "minutes")
        );
    }
    unit(minutes, "minute", "minutes")
}

fn unit(value: u64, singular: &str, plural: &str) -> String {
    if value == 1 {
        format!("1 {singular}")
    } else {
        format!("{} {plural}", group_digits(value as usize))
    }
}

/// The live artwork mosaic. Tiles are Cairo-painted rather than composed from
/// `gtk::Picture`s because every one of them is being scaled, nudged, lifted and
/// crossfaded at once off a single frame clock, and a widget tree cannot express
/// that without a transform per child.
struct Mosaic {
    holder: gtk::ScrolledWindow,
    grid: gtk::GridView,
    store: gio::ListStore,
    tiles: RefCell<Vec<Rc<Tile>>>,
    keyed: RefCell<HashMap<String, usize>>,
    /// What is waiting for a tile: the album key the tile is remembered by,
    /// then the raw title and artist the artwork is looked up with. The two
    /// differ during the tag pass, where a track's credit ("A feat. B") is not
    /// yet the album's derived artist.
    queue: RefCell<VecDeque<(String, String, String)>>,
    /// Every album ever queued. The library is reloaded every few seconds while
    /// enrichment lands covers, and without this each reload would re-queue the
    /// whole library behind the handful of albums that actually changed.
    seen: RefCell<HashSet<String>>,
    cursor: Cell<usize>,
    pumping: Cell<bool>,
    pump_ticks: Cell<u32>,
    driver: FrameDriver,
}

impl Mosaic {
    fn new() -> Rc<Self> {
        let store = gio::ListStore::new::<BoxedAnyObject>();
        let selection = gtk::NoSelection::new(Some(store.clone()));
        let factory = gtk::SignalListItemFactory::new();
        factory.connect_setup(|_, item| {
            let Some(item) = item.downcast_ref::<gtk::ListItem>() else {
                return;
            };
            let area = gtk::DrawingArea::builder()
                .content_width(TILE_SIZE)
                .content_height(TILE_SIZE)
                .build();
            item.set_child(Some(&area));
        });
        factory.connect_bind(|_, item| {
            let Some(item) = item.downcast_ref::<gtk::ListItem>() else {
                return;
            };
            let Some(area) = item.child().and_downcast::<gtk::DrawingArea>() else {
                return;
            };
            let Some(tile) = tile_of(item) else { return };
            *tile.area.borrow_mut() = area.downgrade();
            area.set_draw_func(move |_, cr, width, height| {
                tile.draw(cr, width as f64, height as f64)
            });
            area.queue_draw();
        });
        factory.connect_unbind(|_, item| {
            let Some(item) = item.downcast_ref::<gtk::ListItem>() else {
                return;
            };
            if let Some(tile) = tile_of(item) {
                *tile.area.borrow_mut() = glib::WeakRef::new();
            }
        });

        let grid = gtk::GridView::builder()
            .model(&selection)
            .factory(&factory)
            .min_columns(4)
            .max_columns(4)
            .single_click_activate(false)
            .can_focus(false)
            .build();
        let holder = gtk::ScrolledWindow::builder()
            .hscrollbar_policy(gtk::PolicyType::Never)
            .vscrollbar_policy(gtk::PolicyType::Never)
            .propagate_natural_height(true)
            .propagate_natural_width(true)
            .halign(gtk::Align::Center)
            .child(&grid)
            .build();

        Rc::new(Self {
            holder,
            grid,
            store,
            tiles: RefCell::new(Vec::new()),
            keyed: RefCell::new(HashMap::new()),
            queue: RefCell::new(VecDeque::new()),
            seen: RefCell::new(HashSet::new()),
            cursor: Cell::new(0),
            pumping: Cell::new(false),
            pump_ticks: Cell::new(0),
            driver: FrameDriver::default(),
        })
    }

    /// Grows the grid to `count` slots. A slot with no album yet is a gradient
    /// hashed from its own position, so the mosaic is never blank while the tags
    /// are still being read.
    fn ensure_slots(self: &Rc<Self>, count: usize) {
        let count = count.min(MAX_TILES);
        let mut grew = false;
        while self.tiles.borrow().len() < count {
            let index = self.tiles.borrow().len();
            let tile = Rc::new(Tile::new(&format!("flaccy·slot·{index}")));
            self.tiles.borrow_mut().push(Rc::clone(&tile));
            self.store.append(&BoxedAnyObject::new(tile));
            self.nudge_neighbours(index);
            grew = true;
        }
        if grew {
            self.reflow();
            self.wake();
        }
    }

    fn reflow(&self) {
        let side = grid_side(self.tiles.borrow().len());
        if self.grid.max_columns() != side {
            self.grid.set_min_columns(side);
            self.grid.set_max_columns(side);
        }
    }

    /// Takes every album the library now holds that the mosaic has not already
    /// claimed. Cover lookups go through the shared `ArtworkCache`, so the
    /// mosaic costs one decode per album and shares it with the album grid.
    fn enqueue_library(self: &Rc<Self>, ui: &Rc<Ui>) {
        {
            let library = ui.core.library.borrow();
            let mut seen = self.seen.borrow_mut();
            let mut queue = self.queue.borrow_mut();
            for album in &library.albums {
                if seen.insert(album.key()) {
                    queue.push_back((album.key(), album.title.clone(), album.artist.clone()));
                }
            }
        }
        self.start_pump(ui);
    }

    /// Act I's fuel: covers the tag pass has already written, keyed the way the
    /// build will key them so the reload cannot tile the same album twice, and
    /// looked up under the raw credit the row was written with.
    fn enqueue_hoisted(self: &Rc<Self>, ui: &Rc<Ui>, covers: &[(String, String)]) {
        {
            let mut seen = self.seen.borrow_mut();
            let mut queue = self.queue.borrow_mut();
            for (title, artist) in covers {
                let key = format!("{}|{}", title, crate::hygiene::primary_artist(artist));
                if seen.insert(key.clone()) {
                    queue.push_back((key, title.clone(), artist.clone()));
                }
            }
        }
        self.start_pump(ui);
    }

    fn start_pump(self: &Rc<Self>, ui: &Rc<Ui>) {
        if self.queue.borrow().is_empty() || self.pumping.replace(true) {
            return;
        }
        let weak = Rc::downgrade(self);
        let ui = Rc::clone(ui);
        glib::timeout_add_local(PUMP_INTERVAL, move || {
            let Some(mosaic) = weak.upgrade() else {
                return glib::ControlFlow::Break;
            };
            if !mosaic.pump(&ui) {
                mosaic.pumping.set(false);
                return glib::ControlFlow::Break;
            }
            glib::ControlFlow::Continue
        });
    }

    /// One album per tick while the grid is still filling; once it is full, one
    /// per ~900 ms, recycling the oldest tile. Returns false when the queue has
    /// run dry and the timer should stop.
    fn pump(self: &Rc<Self>, ui: &Rc<Ui>) -> bool {
        if self.queue.borrow().is_empty() {
            return false;
        }
        let filling = self.tiles.borrow().len() < MAX_TILES;
        let ticks = self.pump_ticks.get().wrapping_add(1);
        self.pump_ticks.set(ticks);
        if !filling && ticks % PUMP_TICKS_PER_ROTATION != 0 {
            return true;
        }
        let Some((key, title, artist)) = self.queue.borrow_mut().pop_front() else {
            return false;
        };
        self.adopt(ui, &key, &title, &artist);
        true
    }

    fn adopt(self: &Rc<Self>, ui: &Rc<Ui>, key: &str, title: &str, artist: &str) {
        if self.keyed.borrow().contains_key(key) {
            return;
        }
        let existing = self.tiles.borrow().len();
        let index = if existing < MAX_TILES {
            self.ensure_slots(existing + 1);
            existing
        } else {
            let index = self.cursor.get() % MAX_TILES;
            self.cursor.set(index + 1);
            index
        };
        let Some(tile) = self.tiles.borrow().get(index).cloned() else {
            return;
        };
        self.keyed.borrow_mut().retain(|_, slot| *slot != index);
        self.keyed.borrow_mut().insert(key.to_string(), index);
        tile.reseed(key);
        self.nudge_neighbours(index);
        self.request_cover(ui, &tile, title, artist);
        self.wake();
    }

    fn request_cover(self: &Rc<Self>, ui: &Rc<Ui>, tile: &Rc<Tile>, title: &str, artist: &str) {
        let generation = tile.generation.get();
        let tile = Rc::clone(tile);
        let weak = Rc::downgrade(self);
        ui.core
            .artwork
            .request(title, artist, COVER_REQUEST_SIZE, move |texture, _| {
                let Some(texture) = texture else { return };
                if tile.generation.get() != generation {
                    return;
                }
                tile.set_cover(texture);
                if let Some(mosaic) = weak.upgrade() {
                    mosaic.wake();
                }
            });
    }

    /// Act II's one piece of choreography: the album the job just repaired comes
    /// back to full strength while the rest of the mosaic stays dimmed.
    fn repaired(self: &Rc<Self>, ui: &Rc<Ui>, title: &str, artist: &str) {
        let key = format!("{title}|{artist}");
        let slot = self.keyed.borrow().get(&key).copied();
        let Some(index) = slot else {
            self.queue
                .borrow_mut()
                .push_front((key, title.to_string(), artist.to_string()));
            self.start_pump(ui);
            return;
        };
        let Some(tile) = self.tiles.borrow().get(index).cloned() else {
            return;
        };
        tile.alpha_target.set(1.0);
        self.request_cover(ui, &tile, title, artist);
        self.wake();
    }

    fn dim(self: &Rc<Self>, alpha: f64) {
        for tile in self.tiles.borrow().iter() {
            tile.alpha_target.set(alpha);
        }
        self.wake();
    }

    fn settle(self: &Rc<Self>) {
        for (index, tile) in self.tiles.borrow().iter().enumerate() {
            tile.alpha_target.set(1.0);
            tile.lift.set(-ACT_III_LIFT);
            tile.lift_velocity.set(0.0);
            tile.lift_delay.set(index as f64 * ACT_III_STAGGER);
        }
        self.wake();
    }

    fn retire(&self) {
        self.driver.stop();
        self.queue.borrow_mut().clear();
        self.seen.borrow_mut().clear();
        self.store.remove_all();
        self.tiles.borrow_mut().clear();
        self.keyed.borrow_mut().clear();
    }

    /// Pushes tile `index`'s four neighbours two pixels outward; their own
    /// springs bring them back, which is what makes a tile filling in read as an
    /// event rather than a repaint.
    fn nudge_neighbours(&self, index: usize) {
        let tiles = self.tiles.borrow();
        let side = grid_side(tiles.len()) as usize;
        let neighbours = [
            (index.checked_sub(1), (-NEIGHBOUR_NUDGE, 0.0)),
            (Some(index + 1), (NEIGHBOUR_NUDGE, 0.0)),
            (index.checked_sub(side), (0.0, -NEIGHBOUR_NUDGE)),
            (Some(index + side), (0.0, NEIGHBOUR_NUDGE)),
        ];
        for (neighbour, offset) in neighbours {
            let Some(neighbour) = neighbour else { continue };
            if let Some(tile) = tiles.get(neighbour) {
                tile.nudge.set(offset);
                tile.nudge_velocity.set((0.0, 0.0));
            }
        }
    }

    /// Starts the frame clock if it is not already running. One step advances
    /// every tile and repaints only the ones the virtualized grid currently has
    /// widgets for; the moment nothing is moving it tears itself down, so a
    /// settled mosaic costs nothing at all.
    fn wake(self: &Rc<Self>) {
        let weak = Rc::downgrade(self);
        self.driver.start(&self.grid, move |delta| {
            let Some(mosaic) = weak.upgrade() else { return };
            let animated = animations_enabled();
            let mut settled = true;
            for tile in mosaic.tiles.borrow().iter() {
                settled &= tile.advance(delta, animated);
                if let Some(area) = tile.area.borrow().upgrade() {
                    area.queue_draw();
                }
            }
            if settled {
                mosaic.driver.stop();
            }
        });
    }
}

fn grid_side(count: usize) -> u32 {
    if count <= 16 {
        4
    } else if count <= 25 {
        5
    } else {
        6
    }
}

fn tile_of(item: &gtk::ListItem) -> Option<Rc<Tile>> {
    let boxed = item.item().and_downcast::<BoxedAnyObject>()?;
    let borrowed = boxed.borrow::<Rc<Tile>>();
    Some(Rc::clone(&borrowed))
}

/// One mosaic slot. Every field that moves is a spring or a linear fade so the
/// whole grid can be advanced by one frame-clock step and repainted in place.
struct Tile {
    seed: RefCell<String>,
    surface: RefCell<Option<cairo::ImageSurface>>,
    previous: RefCell<Option<cairo::ImageSurface>>,
    generation: Cell<u64>,
    scale: Cell<f64>,
    scale_velocity: Cell<f64>,
    nudge: Cell<(f64, f64)>,
    nudge_velocity: Cell<(f64, f64)>,
    lift: Cell<f64>,
    lift_velocity: Cell<f64>,
    lift_delay: Cell<f64>,
    alpha: Cell<f64>,
    alpha_target: Cell<f64>,
    fade: Cell<f64>,
    area: RefCell<glib::WeakRef<gtk::DrawingArea>>,
}

impl Tile {
    fn new(seed: &str) -> Self {
        Self {
            seed: RefCell::new(seed.to_string()),
            surface: RefCell::new(None),
            previous: RefCell::new(None),
            generation: Cell::new(0),
            scale: Cell::new(TILE_ENTRY_SCALE),
            scale_velocity: Cell::new(0.0),
            nudge: Cell::new((0.0, 0.0)),
            nudge_velocity: Cell::new((0.0, 0.0)),
            lift: Cell::new(0.0),
            lift_velocity: Cell::new(0.0),
            lift_delay: Cell::new(0.0),
            alpha: Cell::new(0.0),
            alpha_target: Cell::new(1.0),
            fade: Cell::new(1.0),
            area: RefCell::new(glib::WeakRef::new()),
        }
    }

    /// Re-points a slot at a real album. The generation counter is what stops a
    /// cover decode that was queued for the album this slot used to hold from
    /// painting over the one it holds now.
    fn reseed(&self, seed: &str) {
        *self.seed.borrow_mut() = seed.to_string();
        self.generation.set(self.generation.get() + 1);
        *self.previous.borrow_mut() = self.surface.borrow_mut().take();
        self.fade.set(0.0);
        self.scale.set(TILE_ENTRY_SCALE);
        self.scale_velocity.set(0.0);
    }

    fn set_cover(&self, texture: &gdk::MemoryTexture) {
        let Some(surface) = surface_from(texture) else {
            return;
        };
        *self.previous.borrow_mut() = self.surface.borrow_mut().take();
        *self.surface.borrow_mut() = Some(surface);
        self.fade.set(0.0);
    }

    /// Integrates one frame. Returns true once nothing is moving, which is how
    /// the frame driver knows to tear itself down.
    fn advance(&self, delta: f64, animated: bool) -> bool {
        if !animated {
            return self.snap(delta);
        }
        let mut settled = true;

        let (scale, scale_velocity) =
            spring(self.scale.get(), self.scale_velocity.get(), 1.0, delta);
        self.scale.set(scale);
        self.scale_velocity.set(scale_velocity);
        settled &= at_rest(scale, 1.0, scale_velocity);

        let ((x, y), (vx, vy)) = (self.nudge.get(), self.nudge_velocity.get());
        let (x, vx) = spring(x, vx, 0.0, delta);
        let (y, vy) = spring(y, vy, 0.0, delta);
        self.nudge.set((x, y));
        self.nudge_velocity.set((vx, vy));
        settled &= at_rest(x, 0.0, vx) && at_rest(y, 0.0, vy);

        let delay = self.lift_delay.get();
        if delay > 0.0 {
            self.lift_delay.set((delay - delta).max(0.0));
            settled = false;
        } else {
            let (lift, lift_velocity) =
                spring(self.lift.get(), self.lift_velocity.get(), 0.0, delta);
            self.lift.set(lift);
            self.lift_velocity.set(lift_velocity);
            settled &= at_rest(lift, 0.0, lift_velocity);
        }

        settled &= self.advance_fades(delta);
        settled
    }

    fn advance_fades(&self, delta: f64) -> bool {
        let step = delta / CROSSFADE_SECONDS;
        let mut settled = true;

        let (alpha, target) = (self.alpha.get(), self.alpha_target.get());
        if (alpha - target).abs() > 0.002 {
            let next = if alpha < target {
                (alpha + step).min(target)
            } else {
                (alpha - step).max(target)
            };
            self.alpha.set(next);
            settled = false;
        } else {
            self.alpha.set(target);
        }

        let fade = self.fade.get();
        if fade < 1.0 {
            self.fade.set((fade + step).min(1.0));
            settled = false;
        }
        if self.fade.get() >= 1.0 && self.previous.borrow().is_some() {
            *self.previous.borrow_mut() = None;
        }
        settled
    }

    /// The desktop's "reduce animation" preference: everything lands at once and
    /// only the cross-dissolve survives, which is the same concession the Apple
    /// clients make for Reduce Motion.
    fn snap(&self, delta: f64) -> bool {
        self.scale.set(1.0);
        self.scale_velocity.set(0.0);
        self.nudge.set((0.0, 0.0));
        self.nudge_velocity.set((0.0, 0.0));
        self.lift.set(0.0);
        self.lift_velocity.set(0.0);
        self.lift_delay.set(0.0);
        self.advance_fades(delta)
    }

    fn draw(&self, cr: &cairo::Context, width: f64, height: f64) {
        let side = width.min(height);
        let alpha = self.alpha.get().clamp(0.0, 1.0);
        if side <= 1.0 || alpha <= 0.002 {
            return;
        }
        let (nudge_x, nudge_y) = self.nudge.get();
        let _ = cr.save();
        cr.translate(
            width / 2.0 + nudge_x,
            height / 2.0 + nudge_y + self.lift.get(),
        );
        cr.scale(self.scale.get(), self.scale.get());
        cr.translate(-side / 2.0, -side / 2.0);
        rounded_rect(cr, side, TILE_RADIUS);
        cr.clip();
        paint_gradient(cr, &self.seed.borrow(), side, alpha);
        let fade = self.fade.get().clamp(0.0, 1.0);
        if let Some(previous) = self.previous.borrow().as_ref() {
            paint_surface(cr, previous, side, alpha * (1.0 - fade));
        }
        if let Some(surface) = self.surface.borrow().as_ref() {
            paint_surface(cr, surface, side, alpha * fade);
        }
        let _ = cr.restore();
    }
}

/// One step of a damped spring, integrated per frame. `SPRING_RESPONSE` is the
/// period of a full oscillation and `SPRING_DAMPING` the fraction of critical
/// damping, which is exactly how the Apple clients' `.spring(response:damping:)`
/// is parameterised — same numbers, same motion.
fn spring(value: f64, velocity: f64, target: f64, delta: f64) -> (f64, f64) {
    let omega = std::f64::consts::TAU / SPRING_RESPONSE;
    let velocity =
        velocity + (omega * omega * (target - value) - 2.0 * SPRING_DAMPING * omega * velocity) * delta;
    (value + velocity * delta, velocity)
}

fn at_rest(value: f64, target: f64, velocity: f64) -> bool {
    (value - target).abs() < 0.002 && velocity.abs() < 0.02
}

fn animations_enabled() -> bool {
    gtk::Settings::default().is_none_or(|settings| settings.is_gtk_enable_animations())
}

fn rounded_rect(cr: &cairo::Context, side: f64, radius: f64) {
    let radius = radius.min(side / 2.0);
    let half_pi = std::f64::consts::FRAC_PI_2;
    cr.new_sub_path();
    cr.arc(side - radius, radius, radius, -half_pi, 0.0);
    cr.arc(side - radius, side - radius, radius, 0.0, half_pi);
    cr.arc(radius, side - radius, radius, half_pi, std::f64::consts::PI);
    cr.arc(radius, radius, radius, std::f64::consts::PI, 3.0 * half_pi);
    cr.close_path();
}

/// The same deterministic two-stop gradient the album grid uses for a coverless
/// tile, so a slot that never resolves still belongs to the picture.
fn paint_gradient(cr: &cairo::Context, seed: &str, side: f64, alpha: f64) {
    let ((r1, g1, b1), (r2, g2, b2)) = crate::palette::placeholder_colors(seed);
    let gradient = cairo::LinearGradient::new(0.0, 0.0, side, side);
    gradient.add_color_stop_rgb(
        0.0,
        r1 as f64 / 255.0,
        g1 as f64 / 255.0,
        b1 as f64 / 255.0,
    );
    gradient.add_color_stop_rgb(
        1.0,
        r2 as f64 / 255.0,
        g2 as f64 / 255.0,
        b2 as f64 / 255.0,
    );
    if cr.set_source(&gradient).is_ok() {
        let _ = cr.paint_with_alpha(alpha);
    }
}

fn paint_surface(cr: &cairo::Context, surface: &cairo::ImageSurface, side: f64, alpha: f64) {
    if alpha <= 0.002 {
        return;
    }
    let (width, height) = (surface.width() as f64, surface.height() as f64);
    if width <= 0.0 || height <= 0.0 {
        return;
    }
    let scale = (side / width).max(side / height);
    let _ = cr.save();
    cr.translate(
        (side - width * scale) / 2.0,
        (side - height * scale) / 2.0,
    );
    cr.scale(scale, scale);
    if cr.set_source_surface(surface, 0.0, 0.0).is_ok() {
        let _ = cr.paint_with_alpha(alpha);
    }
    let _ = cr.restore();
}

/// Downloads a decoded cover into a Cairo surface exactly once, at the moment it
/// arrives. `gdk_texture_download` always writes premultiplied ARGB32, which is
/// the one format `ImageSurface` can adopt without a conversion pass — doing it
/// per frame instead would put a full-size copy inside the frame clock.
fn surface_from(texture: &gdk::MemoryTexture) -> Option<cairo::ImageSurface> {
    let (width, height) = (texture.width(), texture.height());
    if width <= 0 || height <= 0 {
        return None;
    }
    let stride = cairo::Format::ARgb32.stride_for_width(width as u32).ok()?;
    let mut data = vec![0u8; stride as usize * height as usize];
    texture.download(&mut data, stride as usize);
    cairo::ImageSurface::create_for_data(data, cairo::Format::ARgb32, width, height, stride).ok()
}
