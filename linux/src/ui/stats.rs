use crate::chart_queue::ChartIndex;
use crate::db::Db;
use crate::events::AppEvent;
use crate::library::Track;
use crate::recap::{self, Period, RecapData};
use crate::ui::Ui;
use adw::prelude::*;
use chrono::Datelike;
use flaccy_shared::library_filter::PeriodDelta;
use flaccy_shared::load_progress::group_digits;
use gtk::glib;
use gtk::pango;
use std::cell::{Cell, RefCell};
use std::collections::{HashMap, HashSet};
use std::rc::Rc;
use std::time::{Duration, Instant};

const HEATMAP_CELL: f64 = 13.0;
const HEATMAP_GAP: f64 = 3.0;
const HEATMAP_TOP: f64 = 18.0;

/// How strongly a calendar cell outside the selected period is drawn.
const DIMMED_ALPHA: f64 = 0.35;

/// The period Stats opens on every launch: a week answers "what have I been
/// into", and it is the view that stays instant on any history.
const DEFAULT_PERIOD: Period = Period::Week;

/// How long Last.fm's server-side charts are reused before they are asked for
/// again.
const REMOTE_TTL: Duration = Duration::from_secs(600);

/// How soon to ask again after Last.fm gave nothing usable (offline, a bad
/// moment), so a dropped connection does not stay "fresh" for the full ten
/// minutes.
const REMOTE_RETRY: Duration = Duration::from_secs(60);

/// How long a period's snapshot is trusted without anything having happened to
/// the history: past this it is redrawn from the database, so a page left open
/// overnight does not keep yesterday's "last 7 days".
const SNAPSHOT_TTL: Duration = Duration::from_secs(300);

const REMOTE_LIST_LIMIT: u32 = 10;

type RankedList = Vec<(String, i64)>;

/// Last.fm's own top lists for one period. Each list is optional because any of
/// the three calls can fail or come back empty, and the local list stays in
/// place of one that did.
#[derive(Clone)]
struct RemoteCharts {
    artists: Option<RankedList>,
    albums: Option<RankedList>,
    tracks: Option<RankedList>,
    fetched: Instant,
}

impl RemoteCharts {
    fn is_fresh(&self) -> bool {
        self.fetched.elapsed() < REMOTE_TTL
    }

    /// This answer laid over the previous one: a list that did not come back
    /// this time keeps the Last.fm list already on screen rather than falling
    /// back to the local numbers.
    fn over(self, previous: Option<&RemoteCharts>) -> RemoteCharts {
        let Some(previous) = previous else {
            return self;
        };
        RemoteCharts {
            artists: self.artists.or_else(|| previous.artists.clone()),
            albums: self.albums.or_else(|| previous.albums.clone()),
            tracks: self.tracks.or_else(|| previous.tracks.clone()),
            fetched: self.fetched,
        }
    }

    fn apply(&self, data: &mut RecapData) {
        if let Some(artists) = &self.artists {
            data.top_artists = artists.clone();
        }
        if let Some(albums) = &self.albums {
            data.top_albums = albums.clone();
        }
        if let Some(tracks) = &self.tracks {
            data.top_tracks = tracks.clone();
        }
    }
}

/// The Stats tab. The period bar, busy indicator and every section's slot are
/// built once and refilled, so switching periods never blanks the page: the old
/// content stays until the new snapshot is ready, and a period already seen is
/// shown at once from `snapshots`.
struct Page {
    ui: Rc<Ui>,
    period: Cell<Period>,
    snapshots: RefCell<HashMap<Period, (Rc<RecapData>, Instant)>>,
    remote: RefCell<HashMap<Period, RemoteCharts>>,
    loading: RefCell<HashSet<Period>>,
    remote_loading: RefCell<HashSet<Period>>,
    epoch: Cell<u64>,
    announced_local_only: Cell<bool>,
    import_signed_in: Cell<Option<bool>>,
    stack: gtk::Stack,
    toggles: Vec<(Period, gtk::ToggleButton)>,
    busy: gtk::Box,
    busy_label: gtk::Label,
    tiles: gtk::Box,
    import: gtk::Box,
    heatmap: gtk::Box,
    clock: gtk::Box,
    lists: gtk::Box,
}

pub fn build(ui: &Rc<Ui>) -> gtk::Widget {
    let content = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(24)
        .margin_top(28)
        .margin_bottom(28)
        .margin_start(28)
        .margin_end(28)
        .build();

    let empty = adw::StatusPage::builder()
        .icon_name("flaccy-stats-symbolic")
        .title("No Listening History")
        .description(
            "Play some music and your stats will build up here — or import your Last.fm history.",
        )
        .build();
    if crate::lastfm::keys_available() {
        let import_button = gtk::Button::with_label("Import Last.fm History");
        import_button.add_css_class("pill");
        import_button.add_css_class("suggested-action");
        import_button.set_halign(gtk::Align::Center);
        {
            let ui = Rc::clone(ui);
            import_button.connect_clicked(move |_| crate::importer::start(&ui.core));
        }
        empty.set_child(Some(&import_button));
    }

    let scroll = gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::Never)
        .child(
            &adw::Clamp::builder()
                .maximum_size(980)
                .child(&content)
                .build(),
        )
        .build();
    ui.register_scroller(&scroll);

    let loading_page = gtk::Spinner::builder()
        .spinning(true)
        .width_request(32)
        .height_request(32)
        .halign(gtk::Align::Center)
        .valign(gtk::Align::Center)
        .build();

    let stack = gtk::Stack::new();
    stack.set_hhomogeneous(false);
    stack.set_vhomogeneous(false);
    stack.add_named(&loading_page, Some("loading"));
    stack.add_named(&empty, Some("empty"));
    stack.add_named(&scroll, Some("stats"));
    stack.set_visible_child_name("loading");

    let slot = || {
        gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .build()
    };
    let toggles: Vec<(Period, gtk::ToggleButton)> = recap::ALL_PERIODS
        .iter()
        .map(|period| (*period, gtk::ToggleButton::with_label(period.label())))
        .collect();
    let (busy, busy_label) = busy_indicator();
    let lists = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(24)
        .homogeneous(true)
        .valign(gtk::Align::Start)
        .build();
    let page = Rc::new(Page {
        ui: Rc::clone(ui),
        period: Cell::new(DEFAULT_PERIOD),
        snapshots: RefCell::new(HashMap::new()),
        remote: RefCell::new(HashMap::new()),
        loading: RefCell::new(HashSet::new()),
        remote_loading: RefCell::new(HashSet::new()),
        epoch: Cell::new(0),
        announced_local_only: Cell::new(false),
        import_signed_in: Cell::new(None),
        stack: stack.clone(),
        toggles,
        busy,
        busy_label,
        tiles: slot(),
        import: slot(),
        heatmap: slot(),
        clock: slot(),
        lists,
    });

    content.append(&page.period_bar());
    content.append(&page.tiles);
    content.append(&actions_row(&page));
    content.append(&page.import);
    content.append(&section_title("STREAKS"));
    content.append(&page.heatmap);
    content.append(&section_title("LISTENING CLOCK"));
    content.append(&page.clock);
    content.append(&page.lists);
    page.sync_toggles();

    let dirty = Rc::new(Cell::new(true));
    {
        let page = Rc::clone(&page);
        let dirty = Rc::clone(&dirty);
        let stack_ref = stack.clone();
        ui.core
            .hub
            .subscribe_widget(&stack, move |_, event| match event {
                AppEvent::NaturalEnd(_) | AppEvent::LibraryReloaded => {
                    if stack_ref.is_mapped() {
                        page.invalidate();
                    } else {
                        dirty.set(true);
                    }
                }
                AppEvent::HistoryImport { done, .. } => {
                    if *done && stack_ref.is_mapped() {
                        page.invalidate();
                    } else if *done {
                        dirty.set(true);
                    }
                }
                _ => {}
            });
    }
    {
        let page = Rc::clone(&page);
        stack.connect_map(move |_| {
            if dirty.replace(false) {
                page.invalidate();
            }
        });
    }

    stack.upcast()
}

fn busy_indicator() -> (gtk::Box, gtk::Label) {
    let busy = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(8)
        .valign(gtk::Align::Center)
        .visible(false)
        .build();
    busy.append(&gtk::Spinner::builder().spinning(true).build());
    let label = gtk::Label::new(None);
    label.add_css_class("dim");
    label.add_css_class("caption");
    busy.append(&label);
    (busy, label)
}

impl Page {
    fn period_bar(self: &Rc<Self>) -> gtk::Widget {
        let bar = gtk::Box::builder()
            .orientation(gtk::Orientation::Horizontal)
            .spacing(14)
            .build();
        let linked = gtk::Box::builder()
            .orientation(gtk::Orientation::Horizontal)
            .spacing(6)
            .halign(gtk::Align::Start)
            .build();
        linked.add_css_class("linked");
        for (period, button) in &self.toggles {
            let period = *period;
            let page = Rc::clone(self);
            button.connect_clicked(move |button| {
                if page.period.get() == period {
                    button.set_active(true);
                    return;
                }
                page.select(period);
            });
            linked.append(button);
        }
        bar.append(&linked);
        bar.append(&self.busy);
        bar.upcast()
    }

    fn sync_toggles(&self) {
        let current = self.period.get();
        for (period, button) in &self.toggles {
            button.set_active(*period == current);
        }
    }

    fn select(self: &Rc<Self>, period: Period) {
        self.period.set(period);
        crate::logger::info("ui", &format!("stats period: {}", period.label()));
        self.sync_toggles();
        self.present();
    }

    /// Shows the current period from memory when it has been seen, otherwise
    /// asks for it and leaves the page as it is until the answer lands.
    fn present(self: &Rc<Self>) {
        let period = self.period.get();
        let age = self
            .snapshots
            .borrow()
            .get(&period)
            .map(|(_, taken)| taken.elapsed());
        match age {
            Some(age) => {
                self.render();
                if age > SNAPSHOT_TTL {
                    self.load_local(period);
                }
            }
            None => self.load_local(period),
        }
        self.update_busy();
    }

    /// Forgets every snapshot (the history just changed) and refreshes what is
    /// on screen without clearing it first.
    fn invalidate(self: &Rc<Self>) {
        self.epoch.set(self.epoch.get() + 1);
        self.snapshots.borrow_mut().clear();
        self.present();
    }

    fn load_local(self: &Rc<Self>, period: Period) {
        if !self.loading.borrow_mut().insert(period) {
            return;
        }
        let epoch = self.epoch.get();
        let db_path = self.ui.core.db_path.clone();
        let (tx, rx) = async_channel::bounded::<Option<RecapData>>(1);
        std::thread::Builder::new()
            .name("flaccy-stats".into())
            .spawn(move || {
                let started = Instant::now();
                let data = Db::open(&db_path)
                    .ok()
                    .map(|db| recap::load(&db, period, chrono::Utc::now().timestamp()));
                crate::logger::info(
                    "charts",
                    &format!(
                        "stats {} read in {} ms",
                        period.label(),
                        started.elapsed().as_millis()
                    ),
                );
                let _ = tx.send_blocking(data);
            })
            .ok();
        let page = Rc::clone(self);
        glib::spawn_future_local(async move {
            let data = rx.recv().await.ok().flatten();
            page.loading.borrow_mut().remove(&period);
            let wanted = page.period.get() == period;
            if page.epoch.get() != epoch {
                if wanted {
                    page.load_local(period);
                }
            } else if let Some(data) = data {
                page.snapshots
                    .borrow_mut()
                    .insert(period, (Rc::new(data), Instant::now()));
                if wanted {
                    page.render();
                }
            }
            page.update_busy();
        });
    }

    fn update_busy(&self) {
        let period = self.period.get();
        let local = self.loading.borrow().contains(&period);
        let remote = self.remote_loading.borrow().contains(&period);
        self.busy.set_visible(local || remote);
        self.busy_label.set_label(if remote && !local {
            "Updating from Last.fm…"
        } else {
            ""
        });
    }

    fn render(self: &Rc<Self>) {
        let period = self.period.get();
        let Some(snapshot) = self
            .snapshots
            .borrow()
            .get(&period)
            .map(|(data, _)| Rc::clone(data))
        else {
            return;
        };
        if !snapshot.has_history {
            self.stack.set_visible_child_name("empty");
            return;
        }
        self.stack.set_visible_child_name("stats");
        replace_child(&self.tiles, &tiles_row(&snapshot, period));
        let signed_in = self.ui.core.session.borrow().is_some();
        if self.import_signed_in.replace(Some(signed_in)) != Some(signed_in) {
            replace_child(&self.import, &import_row(&self.ui));
        }
        replace_child(&self.heatmap, &heatmap_widget(&snapshot));
        replace_child(&self.clock, &clock_widget(&snapshot));
        self.fill_lists();
        self.fetch_remote_if_due(period);
    }

    /// The recap as the page shows it: the local snapshot with Last.fm's lists
    /// laid over it when they have arrived.
    fn current(&self) -> Option<(RecapData, Period)> {
        let period = self.period.get();
        let mut data = (*self.snapshots.borrow().get(&period)?.0).clone();
        if let Some(remote) = self.remote.borrow().get(&period) {
            remote.apply(&mut data);
        }
        Some((data, period))
    }

    fn fill_lists(self: &Rc<Self>) {
        let Some((data, _)) = self.current() else {
            return;
        };
        while let Some(child) = self.lists.first_child() {
            self.lists.remove(&child);
        }
        let library = self.ui.core.library.borrow().clone();
        let index = ChartIndex::new(&library);
        self.lists.append(&top_list(
            &self.ui,
            "TOP ARTISTS",
            &data.top_artists,
            ChartKind::Artists,
            &index,
        ));
        self.lists.append(&top_list(
            &self.ui,
            "TOP ALBUMS",
            &data.top_albums,
            ChartKind::Albums,
            &index,
        ));
        self.lists.append(&top_list(
            &self.ui,
            "TOP TRACKS",
            &data.top_tracks,
            ChartKind::Tracks,
            &index,
        ));
    }

    /// Asks Last.fm for its server-side charts without holding anything up:
    /// the local lists are already on screen and swap in place when these land.
    fn fetch_remote_if_due(self: &Rc<Self>, period: Period) {
        let Some(session) = self.ui.core.session.borrow().clone() else {
            if !self.announced_local_only.replace(true) {
                crate::logger::info("charts", "charts: local stats only (not authenticated)");
            }
            return;
        };
        if self
            .remote
            .borrow()
            .get(&period)
            .is_some_and(RemoteCharts::is_fresh)
        {
            return;
        }
        if !self.remote_loading.borrow_mut().insert(period) {
            return;
        }
        self.update_busy();
        let (tx, rx) = async_channel::bounded::<Option<RemoteCharts>>(1);
        std::thread::Builder::new()
            .name("flaccy-charts".into())
            .spawn(move || {
                let _ = tx.send_blocking(fetch_remote_charts(&session, period));
            })
            .ok();
        let page = Rc::clone(self);
        glib::spawn_future_local(async move {
            let charts = rx.recv().await.ok().flatten();
            page.remote_loading.borrow_mut().remove(&period);
            if let Some(charts) = charts {
                let merged = charts.over(page.remote.borrow().get(&period));
                page.remote.borrow_mut().insert(period, merged);
                if page.period.get() == period {
                    page.fill_lists();
                }
            }
            page.update_busy();
        });
    }
}

fn replace_child(slot: &gtk::Box, child: &gtk::Widget) {
    while let Some(old) = slot.first_child() {
        slot.remove(&old);
    }
    slot.append(child);
}

/// Last.fm's top artists, albums and tracks for the period, fetched together
/// rather than one after another (iOS backfillFromNetwork): the server
/// aggregates the whole history, which covers listening done on other devices.
fn fetch_remote_charts(session: &crate::config::Session, period: Period) -> Option<RemoteCharts> {
    let client = crate::lastfm::LastFmClient::new(Some(session.key.clone()))?;
    let api_period = period.api_value();
    let username = session.username.as_str();
    let (artists, albums, tracks) = std::thread::scope(|scope| {
        let artists =
            scope.spawn(|| client.fetch_top_artists(username, api_period, REMOTE_LIST_LIMIT));
        let albums =
            scope.spawn(|| client.fetch_top_albums(username, api_period, REMOTE_LIST_LIMIT));
        let tracks =
            scope.spawn(|| client.fetch_top_tracks(username, api_period, REMOTE_LIST_LIMIT));
        (artists.join(), albums.join(), tracks.join())
    });
    crate::logger::info(
        "charts",
        &format!("charts backfill: Last.fm ({api_period})"),
    );
    let mut charts = RemoteCharts {
        artists: usable_list("artists", artists),
        albums: usable_list("albums", albums).map(|albums| {
            albums
                .into_iter()
                .map(|(album, artist, count, _)| (format!("{album} — {artist}"), count))
                .collect()
        }),
        tracks: usable_list("tracks", tracks).map(|tracks| {
            tracks
                .into_iter()
                .map(|(title, artist, count)| (format!("{title} — {artist}"), count))
                .collect()
        }),
        fetched: Instant::now(),
    };
    if charts.artists.is_none() && charts.albums.is_none() && charts.tracks.is_none() {
        charts.fetched = Instant::now() - (REMOTE_TTL - REMOTE_RETRY);
    }
    Some(charts)
}

/// A fetched list when it is worth showing; `None` for a failure (logged) or an
/// empty answer, either of which leaves the local list in place.
fn usable_list<T>(
    what: &str,
    result: std::thread::Result<Result<Vec<T>, String>>,
) -> Option<Vec<T>> {
    match result {
        Ok(Ok(list)) if !list.is_empty() => Some(list),
        Ok(Ok(_)) | Err(_) => None,
        Ok(Err(err)) => {
            crate::logger::warn("charts", &format!("charts backfill {what} failed: {err}"));
            None
        }
    }
}

fn tiles_row(data: &RecapData, period: Period) -> gtk::Widget {
    let tiles = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(14)
        .homogeneous(true)
        .build();
    let window = period.previous_label();
    let previous = data.previous;
    tiles.append(&stat_tile(
        &format_count(data.total_plays),
        "PLAYS",
        delta_chip(
            previous.map(|p| p.plays),
            data.total_plays,
            "plays",
            window.as_deref(),
        ),
    ));
    tiles.append(&stat_tile(
        &format_count(data.total_minutes),
        "MINUTES",
        delta_chip(
            previous.map(|p| p.minutes),
            data.total_minutes,
            "minutes",
            window.as_deref(),
        ),
    ));
    tiles.append(&stat_tile(
        &data.streak_days.to_string(),
        "DAY STREAK",
        None,
    ));
    tiles.append(&stat_tile(data.persona, "PERSONA", None));
    tiles.upcast()
}

/// The "▲ 12%" chip beside a tile's caption, with the raw numbers in its
/// tooltip. `None` when there is no previous window (All Time) or nothing to
/// compare.
fn delta_chip(
    previous: Option<i64>,
    current: i64,
    unit: &str,
    window: Option<&str>,
) -> Option<gtk::Widget> {
    let previous = previous?;
    let delta = PeriodDelta::compare(current, previous);
    let text = delta.chip_text()?;
    let class = match delta {
        PeriodDelta::Up(_) | PeriodDelta::New => "delta-up",
        PeriodDelta::Down(_) => "delta-down",
        PeriodDelta::Even | PeriodDelta::None => "delta-even",
    };
    let chip = gtk::Label::new(Some(&text));
    chip.add_css_class("delta-chip");
    chip.add_css_class(class);
    chip.set_valign(gtk::Align::Center);
    chip.set_tooltip_text(Some(&format!(
        "{} {unit} · {} in the {}",
        group_digits(current.max(0) as usize),
        group_digits(previous.max(0) as usize),
        window.unwrap_or("previous period"),
    )));
    Some(chip.upcast())
}

/// Share-card and Year in Music entry points for the current recap.
fn actions_row(page: &Rc<Page>) -> gtk::Widget {
    let row = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(10)
        .build();

    let share = gtk::Button::with_label("Share Card");
    share.add_css_class("pill");
    share.set_tooltip_text(Some("Export this recap as a 1080×1350 image"));
    let ui = Rc::clone(&page.ui);
    {
        let ui = Rc::clone(&ui);
        let page = Rc::clone(page);
        share.connect_clicked(move |_| {
            let Some((owned, period)) = page.current() else {
                return;
            };
            let period_name = period.display_name();
            let username = ui
                .core
                .session
                .borrow()
                .as_ref()
                .map(|s| s.username.clone());
            let (tx, rx) = async_channel::bounded::<Option<Vec<u8>>>(1);
            std::thread::Builder::new()
                .name("flaccy-card".into())
                .spawn(move || {
                    let bytes =
                        crate::render::recap_share_card(&owned, period_name, username.as_deref())
                            .and_then(|card| card.png_bytes());
                    let _ = tx.send_blocking(bytes);
                })
                .ok();
            let ui = Rc::clone(&ui);
            glib::spawn_future_local(async move {
                match rx.recv().await {
                    Ok(Some(bytes)) => present_share_options(&ui, bytes),
                    _ => ui.core.toast("Couldn't draw the card — the image couldn't be created or encoded as a PNG. Try again."),
                }
            });
        });
    }
    row.append(&share);

    let yim = gtk::Button::with_label("Year in Music");
    yim.add_css_class("pill");
    {
        let ui = Rc::clone(&ui);
        yim.connect_clicked(move |_| {
            let db_path = ui.core.db_path.clone();
            let (tx, rx) = async_channel::bounded::<Vec<i32>>(1);
            std::thread::Builder::new()
                .name("flaccy-yim-years".into())
                .spawn(move || {
                    let years = Db::open(&db_path)
                        .map(|db| recap::scrobble_years(&db.fetch_all_scrobble_rows()))
                        .unwrap_or_default();
                    let _ = tx.send_blocking(years);
                })
                .ok();
            let ui = Rc::clone(&ui);
            glib::spawn_future_local(async move {
                let years = rx.recv().await.unwrap_or_default();
                crate::ui::year_in_music::present(&ui, years);
            });
        });
    }
    row.append(&yim);
    row.upcast()
}

/// Save-or-copy chooser for a rendered share card: Save PNG… opens a file
/// dialog; Copy Image puts the PNG on the clipboard.
fn present_share_options(ui: &Rc<Ui>, png: Vec<u8>) {
    let dialog = adw::AlertDialog::builder()
        .heading("Share Recap")
        .body("Export the card as a PNG file or copy it to the clipboard.")
        .build();
    dialog.add_response("cancel", "Cancel");
    dialog.add_response("copy", "Copy Image");
    dialog.add_response("save", "Save PNG…");
    dialog.set_response_appearance("save", adw::ResponseAppearance::Suggested);
    let window = ui.window.clone();
    let ui = Rc::clone(ui);
    let pending: Rc<RefCell<Option<Vec<u8>>>> = Rc::new(RefCell::new(Some(png)));
    dialog.connect_response(None, move |_, response| match response {
        "save" => {
            let Some(bytes) = pending.borrow_mut().take() else {
                return;
            };
            crate::ui::year_in_music::save_card(&ui, bytes, "flaccy-recap.png");
        }
        "copy" => {
            let Some(bytes) = pending.borrow_mut().take() else {
                return;
            };
            match gtk::gdk::Texture::from_bytes(&glib::Bytes::from_owned(bytes)) {
                Ok(texture) => {
                    ui.window.clipboard().set_texture(&texture);
                    ui.core.toast("Recap card copied to clipboard");
                }
                Err(err) => {
                    crate::logger::error("ui", &format!("clipboard copy failed: {err}"));
                    ui.core.toast(&format!(
                        "Couldn't copy the card — the clipboard rejected the image ({err}). Save it as a PNG instead."
                    ));
                }
            }
        }
        _ => {}
    });
    dialog.present(Some(&window));
}

fn import_row(ui: &Rc<Ui>) -> gtk::Widget {
    let row = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(12)
        .build();
    if !crate::lastfm::keys_available() || ui.core.session.borrow().is_none() {
        return row.upcast();
    }
    let button = gtk::Button::with_label("Import Last.fm History");
    button.add_css_class("pill");
    let progress = gtk::Label::builder().xalign(0.0).build();
    progress.add_css_class("dim");
    progress.add_css_class("caption");
    progress.set_valign(gtk::Align::Center);
    {
        let ui = Rc::clone(ui);
        let progress = progress.clone();
        button.connect_clicked(move |button| {
            button.set_sensitive(false);
            progress.set_label("Starting import…");
            crate::importer::start(&ui.core);
        });
    }
    {
        let button = button.clone();
        let progress_ref = progress.clone();
        ui.core.hub.subscribe_widget(&row, move |_, event| {
            if let AppEvent::HistoryImport {
                imported,
                page,
                total_pages,
                done,
            } = event
            {
                if *done {
                    button.set_sensitive(true);
                    progress_ref.set_label(&format!("Imported {imported} plays"));
                } else {
                    button.set_sensitive(false);
                    progress_ref.set_label(&format!(
                        "Importing… page {page} of {total_pages} · {imported} plays"
                    ));
                }
            }
        });
    }
    row.append(&button);
    row.append(&progress);
    row.upcast()
}

/// GitHub-style streak heatmap: 7 day rows × N week columns with month labels
/// and a hover tooltip showing the per-day play count.
fn heatmap_widget(data: &Rc<RecapData>) -> gtk::Widget {
    let now = chrono::Utc::now().timestamp();
    let Some(grid) = recap::heatmap_grid(data.heatmap_start, now) else {
        let label = gtk::Label::builder()
            .label("No dated plays yet.")
            .xalign(0.0)
            .build();
        label.add_css_class("dim");
        return label.upcast();
    };
    let grid = Rc::new(grid);
    let width = grid.weeks as f64 * (HEATMAP_CELL + HEATMAP_GAP) + 4.0;
    let height = HEATMAP_TOP + 7.0 * (HEATMAP_CELL + HEATMAP_GAP);

    let area = gtk::DrawingArea::builder()
        .content_width(width as i32)
        .content_height(height as i32)
        .halign(gtk::Align::Start)
        .build();
    let max_count = data.heatmap.values().copied().max().unwrap_or(1).max(1);
    {
        let data = Rc::clone(data);
        let grid = Rc::clone(&grid);
        area.set_draw_func(move |area, cr, _, _| {
            let fg = area.color();
            let (fg_r, fg_g, fg_b) = (fg.red() as f64, fg.green() as f64, fg.blue() as f64);
            let tint = crate::theme::accent_tint();
            let today = chrono::Local::now().date_naive();
            cr.select_font_face(
                "Cantarell",
                gtk::cairo::FontSlant::Normal,
                gtk::cairo::FontWeight::Normal,
            );
            cr.set_font_size(10.0);
            let mut last_month = 0;
            for week in 0..grid.weeks {
                let week_start = grid.start_sunday + chrono::Duration::days(week as i64 * 7);
                if week_start.month() != last_month {
                    last_month = week_start.month();
                    cr.set_source_rgba(fg_r, fg_g, fg_b, 0.5);
                    let x = week as f64 * (HEATMAP_CELL + HEATMAP_GAP);
                    cr.move_to(x, 11.0);
                    let _ = cr.show_text(month_label(last_month));
                }
                for day in 0..7 {
                    let date = week_start + chrono::Duration::days(day as i64);
                    if date > today {
                        continue;
                    }
                    let count = data.heatmap.get(&date).copied().unwrap_or(0);
                    let x = week as f64 * (HEATMAP_CELL + HEATMAP_GAP);
                    let y = HEATMAP_TOP + day as f64 * (HEATMAP_CELL + HEATMAP_GAP);
                    if count == 0 {
                        cr.set_source_rgba(fg_r, fg_g, fg_b, 0.06);
                    } else {
                        let outside = data.period_start.is_some_and(|start| date < start);
                        let fraction = count as f64 / max_count as f64;
                        let alpha = 0.25 + 0.65 * fraction;
                        let alpha = if outside { alpha * DIMMED_ALPHA } else { alpha };
                        cr.set_source_rgba(tint.0, tint.1, tint.2, alpha);
                    }
                    rounded_rect(cr, x, y, HEATMAP_CELL, HEATMAP_CELL, HEATMAP_CELL * 0.28);
                    let _ = cr.fill();
                }
            }
        });
    }
    redraw_on_theme_change(&area);
    area.set_has_tooltip(true);
    {
        let data = Rc::clone(data);
        let grid = Rc::clone(&grid);
        area.connect_query_tooltip(move |_, x, y, _, tooltip| {
            let week = (x as f64 / (HEATMAP_CELL + HEATMAP_GAP)).floor() as i64;
            let day = ((y as f64 - HEATMAP_TOP) / (HEATMAP_CELL + HEATMAP_GAP)).floor() as i64;
            if week < 0 || day < 0 || day > 6 || week >= grid.weeks as i64 {
                return false;
            }
            let date = grid.start_sunday + chrono::Duration::days(week * 7 + day);
            if date > chrono::Local::now().date_naive() {
                return false;
            }
            let count = data.heatmap.get(&date).copied().unwrap_or(0);
            tooltip.set_text(Some(&format!(
                "{} · {} play{}",
                date.format("%b %-d, %Y"),
                count,
                if count == 1 { "" } else { "s" }
            )));
            true
        });
    }

    let scroll = gtk::ScrolledWindow::builder()
        .vscrollbar_policy(gtk::PolicyType::Never)
        .hscrollbar_policy(gtk::PolicyType::Automatic)
        .min_content_height((height + 16.0) as i32)
        .child(&area)
        .build();
    {
        let hadj = scroll.hadjustment();
        glib::idle_add_local_once(move || {
            hadj.set_value(hadj.upper());
        });
    }
    scroll.upcast()
}

/// Repaints a hand-drawn chart when the light/dark setting or the palette
/// changes, and lets go of the global dark-mode handler with the chart: the
/// page redraws its charts on every update, so handlers left behind would pile
/// up for as long as the app runs.
fn redraw_on_theme_change(area: &gtk::DrawingArea) {
    let weak = area.downgrade();
    let handler = adw::StyleManager::default().connect_dark_notify(move |_| {
        if let Some(area) = weak.upgrade() {
            area.queue_draw();
        }
    });
    let handler = RefCell::new(Some(handler));
    area.connect_destroy(move |_| {
        if let Some(handler) = handler.borrow_mut().take() {
            adw::StyleManager::default().disconnect(handler);
        }
    });
    if let Some(controller) = crate::theme::ThemeController::current() {
        controller.connect_changed_widget(area, |area| area.queue_draw());
    }
}

fn month_label(month: u32) -> &'static str {
    match month {
        1 => "Jan",
        2 => "Feb",
        3 => "Mar",
        4 => "Apr",
        5 => "May",
        6 => "Jun",
        7 => "Jul",
        8 => "Aug",
        9 => "Sep",
        10 => "Oct",
        11 => "Nov",
        _ => "Dec",
    }
}

fn rounded_rect(cr: &gtk::cairo::Context, x: f64, y: f64, w: f64, h: f64, r: f64) {
    use std::f64::consts::FRAC_PI_2;
    cr.new_sub_path();
    cr.arc(x + w - r, y + r, r, -FRAC_PI_2, 0.0);
    cr.arc(x + w - r, y + h - r, r, 0.0, FRAC_PI_2);
    cr.arc(x + r, y + h - r, r, FRAC_PI_2, 2.0 * FRAC_PI_2);
    cr.arc(x + r, y + r, r, 2.0 * FRAC_PI_2, 3.0 * FRAC_PI_2);
    cr.close_path();
}

fn clock_widget(data: &Rc<RecapData>) -> gtk::Widget {
    let clock = gtk::DrawingArea::builder()
        .content_height(280)
        .hexpand(true)
        .build();
    let buckets = data.clock;
    clock.set_draw_func(move |area, cr, width, height| {
        draw_listening_clock(area, cr, width as f64, height as f64, &buckets);
    });
    redraw_on_theme_change(&clock);
    clock.upcast()
}

fn format_count(value: i64) -> String {
    if value >= 10_000 {
        format!("{:.1}k", value as f64 / 1000.0)
    } else {
        value.to_string()
    }
}

fn stat_tile(value: &str, caption: &str, delta: Option<gtk::Widget>) -> gtk::Widget {
    let tile = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(4)
        .build();
    tile.add_css_class("stat-tile");
    let value_label = gtk::Label::builder()
        .label(value)
        .xalign(0.0)
        .ellipsize(pango::EllipsizeMode::End)
        .build();
    value_label.add_css_class("stat-value");
    tile.append(&value_label);
    let caption_row = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(8)
        .build();
    let caption_label = gtk::Label::builder().label(caption).xalign(0.0).build();
    caption_label.add_css_class("stat-caption");
    caption_row.append(&caption_label);
    if let Some(delta) = delta {
        caption_row.append(&delta);
    }
    tile.append(&caption_row);
    tile.upcast()
}

fn section_title(text: &str) -> gtk::Widget {
    let label = gtk::Label::builder().label(text).xalign(0.0).build();
    label.add_css_class("stat-caption");
    label.upcast()
}

#[derive(Clone, Copy)]
enum ChartKind {
    Artists,
    Albums,
    Tracks,
}

/// Renders a ranked name/count list that plays. The header's Play and Shuffle
/// queue every entry the library owns; clicking an owned row plays it (a song
/// within the whole chart, an album, an artist as a station) and right-clicking
/// opens the usual menu, which is also how to reach the artist or album page.
fn top_list(
    ui: &Rc<Ui>,
    title: &str,
    rows: &[(String, i64)],
    kind: ChartKind,
    index: &ChartIndex,
) -> gtk::Widget {
    let queue = Rc::new(match kind {
        ChartKind::Artists => index.artist_queue(rows),
        ChartKind::Albums => index.album_queue(rows),
        ChartKind::Tracks => index.track_queue(rows),
    });
    let column = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(10)
        .build();
    column.append(&list_header(ui, title, &queue));
    if rows.is_empty() {
        let label = gtk::Label::builder()
            .label("No plays yet")
            .xalign(0.0)
            .build();
        label.add_css_class("dim");
        column.append(&label);
    }
    for (position, (name, count)) in rows.iter().enumerate() {
        let row = list_row(position + 1, name, *count);
        match kind {
            ChartKind::Artists => {
                if index.owns_artist(name) {
                    make_playable(&row);
                    let artist = name.clone();
                    let ui_click = Rc::clone(ui);
                    on_row_click(&row, move || ui_click.core.start_artist_station(&artist));
                    crate::ui::context::attach_artist_context_menu(&row, name.clone());
                }
            }
            ChartKind::Albums => {
                if let Some(album) = index.album(name) {
                    make_playable(&row);
                    let key = album.key();
                    let ui_click = Rc::clone(ui);
                    let play_key = key.clone();
                    on_row_click(&row, move || ui_click.core.play_album_key(&play_key, false));
                    crate::ui::context::attach_album_context_menu(&row, &ui.core, key);
                }
            }
            ChartKind::Tracks => {
                if let Some(track) = index.track(name) {
                    make_playable(&row);
                    let ui_click = Rc::clone(ui);
                    let queue = Rc::clone(&queue);
                    let rel_path = track.rel_path.clone();
                    let start_path = rel_path.clone();
                    on_row_click(&row, move || {
                        if let Some(start) = queue.iter().position(|t| t.rel_path == start_path) {
                            ui_click.core.play_tracks(queue.to_vec(), start);
                        }
                    });
                    crate::ui::context::attach_track_context_menu(&row, &ui.core, rel_path);
                }
            }
        }
        column.append(&row);
    }
    column.upcast()
}

fn list_header(ui: &Rc<Ui>, title: &str, queue: &Rc<Vec<Track>>) -> gtk::Widget {
    let header = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(4)
        .build();
    let caption = section_title(title);
    caption.set_hexpand(true);
    caption.set_valign(gtk::Align::Center);
    header.append(&caption);
    if queue.is_empty() {
        return header.upcast();
    }
    for (icon, tooltip, shuffle) in [
        ("media-playback-start-symbolic", "Play", false),
        ("media-playlist-shuffle-symbolic", "Shuffle", true),
    ] {
        let button = gtk::Button::from_icon_name(icon);
        button.add_css_class("flat");
        button.add_css_class("circular");
        button.set_tooltip_text(Some(&format!("{tooltip} {}", title.to_lowercase())));
        let ui = Rc::clone(ui);
        let queue = Rc::clone(queue);
        let seed = title.to_string();
        button.connect_clicked(move |_| ui.core.play_list(queue.to_vec(), shuffle, &seed));
        header.append(&button);
    }
    header.upcast()
}

fn list_row(rank_number: usize, name: &str, count: i64) -> gtk::Box {
    let row = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(10)
        .build();
    row.add_css_class("top-list-row");
    let rank = gtk::Label::builder()
        .label(format!("{rank_number}"))
        .width_chars(2)
        .xalign(1.0)
        .build();
    rank.add_css_class("top-list-rank");
    row.append(&rank);
    let name_label = gtk::Label::builder()
        .label(name)
        .xalign(0.0)
        .hexpand(true)
        .ellipsize(pango::EllipsizeMode::End)
        .tooltip_text(name)
        .build();
    row.append(&name_label);
    let count_label = gtk::Label::new(Some(&count.to_string()));
    count_label.add_css_class("duration-label");
    row.append(&count_label);
    row
}

fn make_playable(row: &gtk::Box) {
    row.add_css_class("playable");
    row.set_cursor_from_name(Some("pointer"));
}

fn on_row_click(row: &gtk::Box, play: impl Fn() + 'static) {
    let click = gtk::GestureClick::builder()
        .button(gtk::gdk::BUTTON_PRIMARY)
        .build();
    click.connect_released(move |_, _, _, _| play());
    row.add_controller(click);
}

/// Port of the iOS ListeningClockView radial-spoke drawing.
fn draw_listening_clock(
    area: &gtk::DrawingArea,
    cr: &gtk::cairo::Context,
    width: f64,
    height: f64,
    buckets: &[i64; 24],
) {
    let fg = area.color();
    let (fg_r, fg_g, fg_b) = (fg.red() as f64, fg.green() as f64, fg.blue() as f64);
    let tint = crate::theme::accent_tint();
    let center_x = width / 2.0;
    let center_y = height / 2.0;
    let outer = (width.min(height)) / 2.0 - 6.0;
    let inner = outer * 0.42;
    let max_count = buckets.iter().copied().max().unwrap_or(0).max(1) as f64;

    cr.set_line_cap(gtk::cairo::LineCap::Round);
    for hour in 0..24 {
        let angle = hour as f64 / 24.0 * std::f64::consts::TAU - std::f64::consts::FRAC_PI_2;
        let fraction = buckets[hour] as f64 / max_count;
        let start = (
            center_x + angle.cos() * inner,
            center_y + angle.sin() * inner,
        );
        let track_end = (
            center_x + angle.cos() * outer,
            center_y + angle.sin() * outer,
        );
        cr.set_source_rgba(fg_r, fg_g, fg_b, 0.08);
        cr.set_line_width(3.0);
        cr.move_to(start.0, start.1);
        cr.line_to(track_end.0, track_end.1);
        let _ = cr.stroke();

        if buckets[hour] > 0 {
            let tip = inner + (outer - inner) * fraction;
            let end = (center_x + angle.cos() * tip, center_y + angle.sin() * tip);
            cr.set_source_rgba(tint.0, tint.1, tint.2, 0.45 + 0.55 * fraction);
            cr.set_line_width(5.0);
            cr.move_to(start.0, start.1);
            cr.line_to(end.0, end.1);
            let _ = cr.stroke();
        }
    }

    let total: i64 = buckets.iter().sum();
    if total == 0 {
        return;
    }
    let peak = buckets
        .iter()
        .enumerate()
        .max_by_key(|(_, count)| **count)
        .map(|(hour, _)| hour)
        .unwrap_or(0);

    cr.select_font_face(
        "Cantarell",
        gtk::cairo::FontSlant::Normal,
        gtk::cairo::FontWeight::Bold,
    );
    cr.set_font_size(24.0);
    cr.set_source_rgba(fg_r, fg_g, fg_b, 1.0);
    let text = format!("{:02}:00", peak);
    if let Ok(extents) = cr.text_extents(&text) {
        cr.move_to(center_x - extents.width() / 2.0, center_y + 4.0);
        let _ = cr.show_text(&text);
    }
    cr.set_font_size(10.0);
    cr.set_source_rgba(fg_r, fg_g, fg_b, 0.5);
    if let Ok(extents) = cr.text_extents("PEAK") {
        cr.move_to(center_x - extents.width() / 2.0, center_y + 22.0);
        let _ = cr.show_text("PEAK");
    }
}
