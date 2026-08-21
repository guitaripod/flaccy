use crate::config::{self, Session};
use crate::events::AppEvent;
use crate::lastfm::{self, LastFmClient};
use crate::musicvideo;
use crate::ui::Ui;
use adw::prelude::*;
use flaccy_shared::enrichment_job::{copy as job_copy, Activity, JobProgress, Scope};
use flaccy_shared::library_debut::copy as debut_copy;
use gtk::glib;
use gtk::gio;
use std::cell::RefCell;
use std::rc::Rc;

pub fn present(ui: &Rc<Ui>) {
    let dialog = adw::PreferencesDialog::builder().title("Preferences").build();
    let page = adw::PreferencesPage::builder()
        .title("General")
        .icon_name("emblem-system-symbolic")
        .build();

    page.add(&hero_group(ui));
    page.add(&appearance_group(ui));
    page.add(&lyrics_group(ui));
    if musicvideo::available() {
        page.add(&music_video_group(ui));
    }
    page.add(&library_group(ui));
    page.add(&metadata_group(ui));
    if lastfm::keys_available() {
        page.add(&lastfm_group(ui));
    }
    page.add(&about_group());

    dialog.add(&page);
    dialog.present(Some(&ui.window));
    republish_job_progress(ui);
}

/// The Metadata rows are fed by the job's own event rather than by whatever it
/// happened to be when the page was built, so opening Preferences mid-pass
/// re-reads the countdown from the database instead of showing a stale one.
fn republish_job_progress(ui: &Rc<Ui>) {
    let weak = Rc::downgrade(&ui.core);
    glib::idle_add_local_once(move || {
        if let Some(core) = weak.upgrade() {
            core.refresh_job_progress();
        }
    });
}

/// A branded banner atop Preferences: an app glyph, the wordmark, and a live
/// dashboard of the library — Albums, Tracks and all-time Plays. Its background
/// keys off the same accent tokens as the rest of the app, so it retints with
/// the active theme.
fn hero_group(ui: &Rc<Ui>) -> adw::PreferencesGroup {
    let group = adw::PreferencesGroup::new();
    group.add(&build_hero(ui));
    group
}

fn build_hero(ui: &Rc<Ui>) -> gtk::Box {
    let hero = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(20)
        .build();
    hero.add_css_class("flaccy-hero");
    hero.append(&hero_identity());

    let (albums, tracks) = {
        let library = ui.core.library.borrow().clone();
        (library.albums.len(), library.tracks.len())
    };
    let plays = ui.core.db.scrobble_count().max(0) as u64;

    let (albums_col, albums_value) = stat_column(&group_thousands(albums as u64), "Albums");
    let (tracks_col, tracks_value) = stat_column(&group_thousands(tracks as u64), "Tracks");
    let (plays_col, plays_value) = stat_column(&group_thousands(plays), "Plays");

    let stats = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    stats.add_css_class("flaccy-hero-stats");
    stats.append(&albums_col);
    stats.append(&hero_divider());
    stats.append(&tracks_col);
    stats.append(&hero_divider());
    stats.append(&plays_col);
    hero.append(&stats);

    let hero_ui = Rc::clone(ui);
    ui.core.hub.subscribe_widget(&hero, move |_hero, event| {
        let changed = matches!(
            event,
            AppEvent::LibraryReloaded
                | AppEvent::ScanFinished { .. }
                | AppEvent::NaturalEnd(_)
                | AppEvent::HistoryImport { done: true, .. }
        );
        if !changed {
            return;
        }
        let library = hero_ui.core.library.borrow().clone();
        albums_value.set_label(&group_thousands(library.albums.len() as u64));
        tracks_value.set_label(&group_thousands(library.tracks.len() as u64));
        plays_value.set_label(&group_thousands(hero_ui.core.db.scrobble_count().max(0) as u64));
    });

    hero
}

fn hero_identity() -> gtk::Box {
    let glyph = gtk::Image::from_icon_name("audio-x-generic-symbolic");
    glyph.set_pixel_size(24);
    glyph.add_css_class("flaccy-hero-glyph");
    glyph.set_valign(gtk::Align::Center);

    let wordmark = gtk::Label::builder().label("flaccy").xalign(0.0).build();
    wordmark.add_css_class("flaccy-hero-title");
    let tagline = gtk::Label::builder()
        .label("Your lossless library")
        .xalign(0.0)
        .build();
    tagline.add_css_class("flaccy-hero-tagline");

    let labels = gtk::Box::new(gtk::Orientation::Vertical, 1);
    labels.set_valign(gtk::Align::Center);
    labels.append(&wordmark);
    labels.append(&tagline);

    let row = gtk::Box::new(gtk::Orientation::Horizontal, 14);
    row.append(&glyph);
    row.append(&labels);
    row
}

/// One dashboard column: a big count over a letterspaced caption. Returns the
/// value label so the count can be refreshed live.
fn stat_column(value: &str, caption: &str) -> (gtk::Box, gtk::Label) {
    let column = gtk::Box::new(gtk::Orientation::Vertical, 3);
    column.set_hexpand(true);
    column.set_halign(gtk::Align::Center);
    let value_label = gtk::Label::new(Some(value));
    value_label.add_css_class("stat-value");
    let caption_label = gtk::Label::new(Some(caption));
    caption_label.add_css_class("stat-caption");
    column.append(&value_label);
    column.append(&caption_label);
    (column, value_label)
}

fn hero_divider() -> gtk::Box {
    let divider = gtk::Box::new(gtk::Orientation::Vertical, 0);
    divider.add_css_class("flaccy-hero-divider");
    divider.set_valign(gtk::Align::Center);
    divider
}

/// Formats an integer with thousands separators (locale-agnostic commas), so
/// the dashboard reads "6,945" rather than "6945".
fn group_thousands(n: u64) -> String {
    let digits = n.to_string();
    let len = digits.len();
    let mut out = String::with_capacity(len + (len.saturating_sub(1)) / 3);
    for (i, ch) in digits.chars().enumerate() {
        if i > 0 && (len - i) % 3 == 0 {
            out.push(',');
        }
        out.push(ch);
    }
    out
}

fn appearance_group(ui: &Rc<Ui>) -> adw::PreferencesGroup {
    let group = adw::PreferencesGroup::builder().title("Appearance").build();
    let model = gtk::StringList::new(&["System", "Light", "Dark"]);
    let row = adw::ComboRow::builder()
        .title("Color Scheme")
        .subtitle("Follow the system or force a look")
        .model(&model)
        .build();
    let selected = match ui.core.config.borrow().appearance.as_str() {
        "light" => 1,
        "dark" => 2,
        _ => 0,
    };
    row.set_selected(selected);
    {
        let ui = Rc::clone(ui);
        row.connect_selected_notify(move |row| {
            let appearance = match row.selected() {
                1 => "light",
                2 => "dark",
                _ => "system",
            };
            ui.core.config.borrow_mut().appearance = appearance.to_string();
            ui.core.save_config();
            crate::ui::window::apply_color_scheme(appearance);
            crate::logger::info("ui", &format!("appearance set to {appearance}"));
        });
    }
    group.add(&row);
    group.add(&theme_row(ui));
    group
}

/// Theme picker: Adaptive (follows the playing album) plus curated palettes.
/// Applying is live — the whole app retints instantly via ThemeController.
fn theme_row(ui: &Rc<Ui>) -> adw::ComboRow {
    use crate::theme::Theme;
    let titles: Vec<&str> = Theme::ALL.iter().map(|t| t.title()).collect();
    let model = gtk::StringList::new(&titles);
    let row = adw::ComboRow::builder()
        .title("Theme")
        .subtitle("How Flaccy colors itself")
        .model(&model)
        .build();
    let current = Theme::from_id(&ui.core.config.borrow().theme);
    let selected = Theme::ALL.iter().position(|t| *t == current).unwrap_or(0);
    row.set_selected(selected as u32);
    row.set_subtitle(current.subtitle());

    let swatch = gtk::Box::new(gtk::Orientation::Vertical, 0);
    swatch.add_css_class("theme-swatch");
    swatch.set_valign(gtk::Align::Center);
    apply_swatch(&swatch, current);
    row.add_prefix(&swatch);
    {
        let ui = Rc::clone(ui);
        let swatch = swatch.clone();
        row.connect_selected_notify(move |row| {
            let theme = Theme::ALL
                .get(row.selected() as usize)
                .copied()
                .unwrap_or(Theme::Adaptive);
            row.set_subtitle(theme.subtitle());
            apply_swatch(&swatch, theme);
            ui.core.config.borrow_mut().theme = theme.id().to_string();
            ui.core.save_config();
            if let Some(controller) = crate::theme::ThemeController::current() {
                controller.set_theme(theme);
            }
            crate::logger::info("ui", &format!("theme set to {}", theme.id()));
        });
    }
    row
}

/// Swaps the `swatch-<id>` class so the picker's dot previews the theme color.
fn apply_swatch(swatch: &gtk::Box, theme: crate::theme::Theme) {
    for other in crate::theme::Theme::ALL {
        swatch.remove_css_class(&format!("swatch-{}", other.id()));
    }
    swatch.add_css_class(&format!("swatch-{}", theme.id()));
}

/// Lyrics typography. Applying is live — every open lyrics view (sidebar and
/// the Now Playing column) restyles through the shared CSS provider.
fn lyrics_group(ui: &Rc<Ui>) -> adw::PreferencesGroup {
    let group = adw::PreferencesGroup::builder()
        .title("Lyrics")
        .description("Synced lyrics from your own .lrc files and tags, falling back to lrclib.net")
        .build();
    let row = adw::SpinRow::with_range(
        config::LYRICS_FONT_MIN as f64,
        config::LYRICS_FONT_MAX as f64,
        1.0,
    );
    row.set_title("Text Size");
    row.set_subtitle("How large lyric lines are drawn");
    row.set_value(ui.core.config.borrow().lyrics_font_size as f64);
    {
        let ui = Rc::clone(ui);
        row.connect_value_notify(move |row| {
            let size = row.value().round() as i32;
            if ui.core.config.borrow().lyrics_font_size == size {
                return;
            }
            ui.core.config.borrow_mut().lyrics_font_size = size;
            ui.core.save_config();
            crate::ui::lyrics_style::apply(size);
            crate::logger::info("ui", &format!("lyrics text size set to {size}"));
        });
    }
    group.add(&row);
    group
}

/// Music video mode: what the video lens streams, who decides which video is
/// the right one, and whether the picture is aligned to the audio by ear.
fn music_video_group(ui: &Rc<Ui>) -> adw::PreferencesGroup {
    let group = adw::PreferencesGroup::builder()
        .title("Music Videos")
        .description(
            "The video lens in Now Playing streams a song's music video and locks it to your \
             lossless audio",
        )
        .build();

    let quality = adw::ComboRow::builder()
        .title("Quality")
        .subtitle("The tallest stream the lens will ask for")
        .model(&gtk::StringList::new(
            &musicvideo::QUALITY_HEIGHTS
                .iter()
                .map(|height| musicvideo::quality_label(*height))
                .collect::<Vec<_>>()
                .iter()
                .map(String::as_str)
                .collect::<Vec<_>>(),
        ))
        .build();
    let configured = ui.core.config.borrow().music_video_quality;
    quality.set_selected(
        musicvideo::QUALITY_HEIGHTS
            .iter()
            .position(|height| *height == configured)
            .unwrap_or(2) as u32,
    );
    {
        let ui = Rc::clone(ui);
        quality.connect_selected_notify(move |row| {
            let Some(height) = musicvideo::QUALITY_HEIGHTS.get(row.selected() as usize) else {
                return;
            };
            if ui.core.config.borrow().music_video_quality == *height {
                return;
            }
            ui.core.config.borrow_mut().music_video_quality = *height;
            ui.core.save_config();
            musicvideo::refresh(&ui.core);
        });
    }
    group.add(&quality);

    let align = adw::SwitchRow::builder()
        .title("Align to Your Audio")
        .subtitle("Listens to both recordings once and works out the video's head start")
        .active(ui.core.config.borrow().music_video_align)
        .build();
    {
        let ui = Rc::clone(ui);
        align.connect_active_notify(move |row| {
            ui.core.config.borrow_mut().music_video_align = row.is_active();
            ui.core.save_config();
        });
    }
    group.add(&align);

    let models = musicvideo::llm::installed_models();
    let chosen = musicvideo::llm::choose_model(&ui.core.config.borrow().music_video_llm_model, &models);
    let judge = adw::SwitchRow::builder()
        .title("Let a Local Model Decide")
        .subtitle(match &chosen {
            Some(model) => format!("Ollama breaks ties between close results using {model}"),
            None => "No Ollama model found — the scorer decides on its own".to_string(),
        })
        .active(ui.core.config.borrow().music_video_llm)
        .sensitive(chosen.is_some())
        .build();
    {
        let ui = Rc::clone(ui);
        judge.connect_active_notify(move |row| {
            ui.core.config.borrow_mut().music_video_llm = row.is_active();
            ui.core.save_config();
        });
    }
    group.add(&judge);

    if models.len() > 1 {
        group.add(&model_row(ui, &models));
    }

    let matched = ui.core.db.music_video_count();
    let remembered = adw::ActionRow::builder()
        .title("Remembered Matches")
        .subtitle(match matched {
            0 => "Nothing matched yet".to_string(),
            1 => "1 song has a video".to_string(),
            count => format!("{count} songs have a video"),
        })
        .build();
    let forget = gtk::Button::with_label("Forget All");
    forget.set_valign(gtk::Align::Center);
    forget.add_css_class("destructive-action");
    forget.set_sensitive(matched > 0);
    {
        let ui = Rc::clone(ui);
        let remembered = remembered.clone();
        forget.connect_clicked(move |button| {
            let cleared = ui.core.db.clear_music_videos();
            remembered.set_subtitle("Nothing matched yet");
            button.set_sensitive(false);
            ui.core.toast(&format!("Forgot {cleared} music video matches"));
            musicvideo::refresh(&ui.core);
        });
    }
    remembered.add_suffix(&forget);
    group.add(&remembered);

    group
}

/// Only shown when there is a choice to make: which installed Ollama model
/// gets the casting vote.
fn model_row(ui: &Rc<Ui>, models: &[String]) -> adw::ComboRow {
    let mut names = vec!["Automatic".to_string()];
    names.extend(models.iter().cloned());
    let row = adw::ComboRow::builder()
        .title("Model")
        .model(&gtk::StringList::new(
            &names.iter().map(String::as_str).collect::<Vec<_>>(),
        ))
        .build();
    let configured = ui.core.config.borrow().music_video_llm_model.clone();
    row.set_selected(
        names
            .iter()
            .position(|name| *name == configured)
            .unwrap_or(0) as u32,
    );
    let ui = Rc::clone(ui);
    row.connect_selected_notify(move |row| {
        let selected = row.selected() as usize;
        let chosen = if selected == 0 {
            String::new()
        } else {
            names.get(selected).cloned().unwrap_or_default()
        };
        if ui.core.config.borrow().music_video_llm_model == chosen {
            return;
        }
        ui.core.config.borrow_mut().music_video_llm_model = chosen;
        ui.core.save_config();
    });
    row
}

fn library_group(ui: &Rc<Ui>) -> adw::PreferencesGroup {
    let group = adw::PreferencesGroup::builder().title("Library").build();

    let folder_row = adw::ActionRow::builder()
        .title("Music Folder")
        .subtitle(ui.core.music_root().display().to_string())
        .build();
    let choose = gtk::Button::with_label("Choose…");
    choose.set_valign(gtk::Align::Center);
    {
        let ui = Rc::clone(ui);
        let folder_row = folder_row.clone();
        choose.connect_clicked(move |_| {
            let dialog = gtk::FileDialog::builder().title("Choose Music Folder").build();
            let ui = Rc::clone(&ui);
            let window = ui.window.clone();
            let folder_row = folder_row.clone();
            dialog.select_folder(
                Some(&window),
                None::<&gio::Cancellable>,
                move |result| {
                    let Ok(folder) = result else { return };
                    let Some(path) = folder.path() else { return };
                    crate::logger::info(
                        "library",
                        &format!("music folder changed to {}", path.display()),
                    );
                    ui.core.config.borrow_mut().music_dir =
                        Some(path.display().to_string());
                    ui.core.save_config();
                    ui.core.player.set_root(path.clone());
                    folder_row.set_subtitle(&path.display().to_string());
                    ui.core.rescan();
                },
            );
        });
    }
    folder_row.add_suffix(&choose);
    group.add(&folder_row);

    let autoplay_row = adw::SwitchRow::builder()
        .title("Autoplay Similar Music")
        .subtitle("Keep the music going when the queue ends")
        .active(ui.core.config.borrow().autoplay_continuation)
        .build();
    {
        let ui = Rc::clone(ui);
        autoplay_row.connect_active_notify(move |row| {
            ui.core.config.borrow_mut().autoplay_continuation = row.is_active();
            ui.core.save_config();
            crate::logger::info(
                "ui",
                &format!("autoplay continuation set to {}", row.is_active()),
            );
        });
    }
    group.add(&autoplay_row);

    let group_editions_row = adw::SwitchRow::builder()
        .title("Group Album Editions")
        .subtitle("Fold deluxe, remaster and explicit variants into one album; keep one best copy of each song")
        .active(ui.core.config.borrow().group_album_editions)
        .build();
    {
        let ui = Rc::clone(ui);
        group_editions_row.connect_active_notify(move |row| {
            ui.core.config.borrow_mut().group_album_editions = row.is_active();
            ui.core.save_config();
            crate::logger::info(
                "ui",
                &format!("group album editions set to {}", row.is_active()),
            );
            ui.core.reload_library();
        });
    }
    group.add(&group_editions_row);

    let rescan_row = adw::ActionRow::builder()
        .title("Rescan Library")
        .subtitle("Diff the folder against the database")
        .build();
    let rescan = gtk::Button::builder()
        .child(&adw::ButtonContent::builder().icon_name("view-refresh-symbolic").label("Rescan").build())
        .valign(gtk::Align::Center)
        .build();
    {
        let ui = Rc::clone(ui);
        rescan.connect_clicked(move |_| ui.core.rescan());
    }
    rescan_row.add_suffix(&rescan);
    group.add(&rescan_row);

    let cleanup_row = adw::ActionRow::builder()
        .title("Clean Up Library…")
        .subtitle("Trash duplicate files and merge album editions")
        .build();
    let cleanup = gtk::Button::builder()
        .child(&adw::ButtonContent::builder().icon_name("edit-clear-all-symbolic").label("Clean Up…").build())
        .valign(gtk::Align::Center)
        .build();
    cleanup.add_css_class("destructive-action");
    {
        let ui = Rc::clone(ui);
        cleanup.connect_clicked(move |_| crate::ui::cleanup::present(&ui));
    }
    cleanup_row.add_suffix(&cleanup);
    group.add(&cleanup_row);

    group
}

/// What the durable enrichment job is holding, on demand. It reads as a
/// countdown and a tally, never as a bar: the work is unbounded network work,
/// and `exhausted` is genuinely terminal, so **Try Again** is one of only two
/// ways an album Flaccy gave up on is ever looked at again.
fn metadata_group(ui: &Rc<Ui>) -> adw::PreferencesGroup {
    let group = adw::PreferencesGroup::builder()
        .title("Metadata")
        .description("Re-fetch artwork and release dates for albums Flaccy gave up on.")
        .build();

    let counts_row = adw::ActionRow::builder().build();
    let retry = gtk::Button::builder()
        .label(job_copy::TRY_AGAIN)
        .valign(gtk::Align::Center)
        .build();
    counts_row.add_suffix(&retry);
    group.add(&counts_row);
    let job = ui.core.job_progress();
    render_metadata_counts(ui, &counts_row, &job);
    retry.set_sensitive(can_retry_albums(ui, &job));

    {
        let ui = Rc::clone(ui);
        retry.connect_clicked(move |button| {
            button.set_sensitive(false);
            let queued = crate::ui::retry_missing_artwork(&ui);
            ui.core
                .toast(&format!("Looking up artwork for {queued} albums…"));
        });
    }
    let gave_up = adw::ExpanderRow::builder()
        .title(job_copy::GAVE_UP_LIST)
        .build();
    let listed: Rc<RefCell<Vec<adw::ActionRow>>> = Rc::new(RefCell::new(Vec::new()));
    group.add(&gave_up);
    fill_gave_up(ui, &gave_up, &listed);

    {
        let ui = Rc::clone(ui);
        let retry = retry.clone();
        let gave_up = gave_up.clone();
        let listed = Rc::clone(&listed);
        ui.core
            .hub
            .clone()
            .subscribe_widget(&counts_row, move |row, event| {
                let AppEvent::EnrichmentProgress(job) = event else {
                    return;
                };
                render_metadata_counts(&ui, row, job);
                retry.set_sensitive(can_retry_albums(&ui, job));
                fill_gave_up(&ui, &gave_up, &listed);
            });
    }

    if let Some(summary) = ui.core.db.library_debut() {
        let built = summary
            .completed_at
            .with_timezone(&chrono::Local)
            .format("%-d %b")
            .to_string();
        let line = debut_copy::settings_permanent_line(
            &built,
            summary.track_count,
            summary.ai_cleaned_tracks,
        );
        group.add(
            &adw::ActionRow::builder()
                .title(line.as_str())
                .subtitle(debut_copy::SETTINGS_CAVEAT_FOOTER)
                .build(),
        );
    }

    group
}

/// Names every album the job gave up on, the way iOS's enrichment report does.
/// The stored key is normalized and lower-cased by design, so a row is titled
/// from the live library where the key still matches one, and from the key's own
/// two halves where it does not — a renamed album is still counted and named
/// rather than silently dropped from a list that claims to be complete.
fn fill_gave_up(ui: &Rc<Ui>, row: &adw::ExpanderRow, listed: &RefCell<Vec<adw::ActionRow>>) {
    for old in listed.borrow_mut().drain(..) {
        row.remove(&old);
    }

    let records = ui.core.db.exhausted_entities(Scope::Album);
    row.set_visible(!records.is_empty());
    row.set_subtitle(&records.len().to_string());

    let names = exhausted_display_names(ui);
    for record in records.iter().take(GAVE_UP_LIST_LIMIT) {
        let when = record
            .last_attempt_at
            .map(|at| at.with_timezone(&chrono::Local).format("%-d %b").to_string())
            .unwrap_or_default();
        let title = names
            .get(&record.key)
            .cloned()
            .unwrap_or_else(|| name_from_key(&record.key));
        let entry = adw::ActionRow::builder()
            .title(glib::markup_escape_text(&title).as_str())
            .subtitle(&job_copy::report_row(
                record.fields,
                record.attempts.max(0) as usize,
                &when,
            ))
            .build();
        row.add_row(&entry);
        listed.borrow_mut().push(entry);
    }
}

/// The longest list worth building eagerly inside a preferences dialog; a
/// library that gave up on more albums than this has a systemic problem the
/// counts row already reports.
const GAVE_UP_LIST_LIMIT: usize = 50;

fn exhausted_display_names(ui: &Rc<Ui>) -> std::collections::HashMap<String, String> {
    let library = ui.core.library.borrow();
    library
        .albums
        .iter()
        .map(|album| {
            (
                flaccy_shared::enrichment_job::key_album(&album.title, &album.artist),
                format!("{} — {}", album.title, album.artist),
            )
        })
        .collect()
}

fn name_from_key(key: &str) -> String {
    let mut parts = key.split('\u{1F}');
    let title = parts.next().unwrap_or_default();
    match parts.next() {
        Some(artist) if !artist.is_empty() => format!("{title} — {artist}"),
        _ => title.to_string(),
    }
}

/// macOS pins its Try Again to `countExhausted(scope: .album)`; Linux's
/// `JobProgress.exhausted` follows `outstanding_scope`, which flips to artists
/// as soon as no album is due — precisely the idle state a user retries from.
/// Ask the database for the album count directly, so a library with nothing to
/// revive shows a greyed-out button rather than a control that does nothing.
fn can_retry_albums(ui: &Rc<Ui>, job: &JobProgress) -> bool {
    job.activity != Activity::Running && ui.core.db.count_exhausted(Scope::Album) > 0
}

/// `Complete · In progress · Gave up`, where "complete" is what is left once the
/// two counts the database can answer are taken off the entities the library
/// actually holds — the report never invents a total of its own.
fn render_metadata_counts(ui: &Rc<Ui>, row: &adw::ActionRow, job: &JobProgress) {
    let total = {
        let library = ui.core.library.borrow();
        match job.scope {
            Scope::Album => library.albums.len(),
            Scope::Artist => library.artists.len(),
            Scope::AiBatch => 0,
        }
    };
    let complete = total.saturating_sub(job.remaining + job.exhausted);
    row.set_title(&job_copy::report_counts(
        complete,
        job.remaining,
        job.exhausted,
    ));
    row.set_subtitle(&job_copy::settled(job.remaining, job.exhausted));
}

fn lastfm_group(ui: &Rc<Ui>) -> adw::PreferencesGroup {
    let group = adw::PreferencesGroup::builder()
        .title("Last.fm")
        .description("Scrobble what you play")
        .build();

    let row = adw::ActionRow::builder().build();
    let button = gtk::Button::new();
    button.set_valign(gtk::Align::Center);
    row.add_suffix(&button);
    group.add(&row);

    let pending_token: Rc<RefCell<Option<String>>> = Rc::new(RefCell::new(None));

    let refresh: Rc<dyn Fn()> = {
        let ui = Rc::clone(ui);
        let row = row.clone();
        let button = button.clone();
        let pending_token = Rc::clone(&pending_token);
        Rc::new(move || {
            let session = ui.core.session.borrow().clone();
            match session {
                Some(session) => {
                    row.set_title(&format!("Connected as {}", session.username));
                    row.set_subtitle("Scrobbling and loved tracks are live");
                    button.set_label("Disconnect");
                    button.remove_css_class("suggested-action");
                    button.add_css_class("destructive-action");
                }
                None => {
                    if pending_token.borrow().is_some() {
                        row.set_title("Waiting for authorization…");
                        row.set_subtitle("Approve flaccy in your browser, then confirm here");
                        button.set_label("I've Authorized");
                    } else {
                        row.set_title("Not Connected");
                        row.set_subtitle("Authorize flaccy with your Last.fm account");
                        button.set_label("Connect…");
                    }
                    button.remove_css_class("destructive-action");
                    button.add_css_class("suggested-action");
                }
            }
        })
    };
    refresh();

    {
        let ui = Rc::clone(ui);
        let pending_token = Rc::clone(&pending_token);
        let refresh = Rc::clone(&refresh);
        button.connect_clicked(move |_| {
            let connected = ui.core.session.borrow().is_some();
            if connected {
                *ui.core.session.borrow_mut() = None;
                config::delete_session();
                crate::scrobbler::disconnect_cleanup(&ui.core);
                *pending_token.borrow_mut() = None;
                refresh();
                return;
            }
            let token = pending_token.borrow().clone();
            match token {
                None => begin_auth(&ui, &pending_token, &refresh),
                Some(token) => finish_auth(&ui, token, &pending_token, &refresh),
            }
        });
    }

    group
}

fn begin_auth(
    ui: &Rc<Ui>,
    pending_token: &Rc<RefCell<Option<String>>>,
    refresh: &Rc<dyn Fn()>,
) {
    let Some(client) = LastFmClient::new(None) else { return };
    let (tx, rx) = async_channel::bounded::<Result<String, String>>(1);
    std::thread::spawn(move || {
        let _ = tx.send_blocking(client.get_token());
    });
    let ui = Rc::clone(ui);
    let pending_token = Rc::clone(pending_token);
    let refresh = Rc::clone(refresh);
    glib::spawn_future_local(async move {
        match rx.recv().await {
            Ok(Ok(token)) => {
                let key = lastfm::credentials().map(|(key, _)| key).unwrap_or("");
                let url = lastfm::auth_url(key, &token);
                *pending_token.borrow_mut() = Some(token);
                refresh();
                gtk::UriLauncher::new(&url).launch(
                    Some(&ui.window),
                    None::<&gio::Cancellable>,
                    |result| {
                        if let Err(err) = result {
                            crate::logger::warn("auth", &format!("browser launch failed: {err}"));
                        }
                    },
                );
                crate::logger::info("auth", "last.fm auth token requested, browser opened");
            }
            Ok(Err(err)) => {
                crate::logger::error("auth", &format!("auth.getToken failed: {err}"));
            }
            Err(_) => {}
        }
    });
}

fn finish_auth(
    ui: &Rc<Ui>,
    token: String,
    pending_token: &Rc<RefCell<Option<String>>>,
    refresh: &Rc<dyn Fn()>,
) {
    let Some(client) = LastFmClient::new(None) else { return };
    let (tx, rx) = async_channel::bounded::<Result<(String, String), String>>(1);
    std::thread::spawn(move || {
        let _ = tx.send_blocking(client.get_session(&token));
    });
    let ui = Rc::clone(ui);
    let pending_token = Rc::clone(pending_token);
    let refresh = Rc::clone(refresh);
    glib::spawn_future_local(async move {
        match rx.recv().await {
            Ok(Ok((key, username))) => {
                let session = Session {
                    key,
                    username: username.clone(),
                };
                config::save_session(&session);
                *ui.core.session.borrow_mut() = Some(session);
                *pending_token.borrow_mut() = None;
                crate::logger::info("auth", &format!("last.fm connected as {username}"));
                ui.core.hub.emit(&AppEvent::LastFmChanged);
                crate::scrobbler::startup_maintenance(&ui.core);
                refresh();
            }
            Ok(Err(err)) => {
                crate::logger::error("auth", &format!("auth.getSession failed: {err}"));
                *pending_token.borrow_mut() = None;
                refresh();
            }
            Err(_) => {}
        }
    });
}

fn about_group() -> adw::PreferencesGroup {
    let group = adw::PreferencesGroup::builder().title("About").build();
    let version_row = adw::ActionRow::builder()
        .title("Flaccy for Linux")
        .subtitle(format!(
            "Version {} · GTK4 + GStreamer · sibling of the iOS FLAC player",
            env!("CARGO_PKG_VERSION")
        ))
        .build();
    group.add(&version_row);
    group
}
