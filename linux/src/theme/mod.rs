pub mod builtin;
pub mod color;
pub mod css;
pub mod look;
pub mod pack;
pub mod store;

pub use look::{Choice, Look};
pub use pack::{AlbumsView, Appearance, CoverShape, Pack, Style};

use crate::config::Config;
use color::Rgb;
use gtk::prelude::*;
use gtk::{gdk, gio, glib};
use std::cell::{Cell, RefCell};
use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::time::Duration;

/// How long a burst of now-playing color changes is gathered before one reload.
const PALETTE_SETTLE: Duration = Duration::from_millis(180);

/// How long a burst of file changes in the themes folder is gathered before
/// the themes are read again; an editor's save is several events.
const FILES_SETTLE: Duration = Duration::from_millis(250);

/// Whether there are visible windows and the compositor has suspended all of
/// them.
fn all_windows_suspended() -> bool {
    let mut shown = gtk::Window::list_toplevels()
        .into_iter()
        .filter_map(|window| window.downcast::<gtk::Window>().ok())
        .filter(|window| window.is_visible())
        .peekable();
    shown.peek().is_some() && shown.all(|window| window.is_suspended())
}

/// Where the person's own themes live, one folder each.
pub fn themes_dir() -> PathBuf {
    dirs::data_dir()
        .unwrap_or_default()
        .join("flaccy")
        .join("themes")
}

/// Owns the look the app wears: which theme, scheme and variant are on, the
/// person's own choices over them, and the swappable CSS providers that carry
/// the result. One provider holds the palette, which follows the playing
/// artwork; the other holds the theme's shape rules and its own stylesheet,
/// which change only when the look does.
pub struct ThemeController {
    palette_provider: gtk::CssProvider,
    look_provider: gtk::CssProvider,
    themes_dir: PathBuf,
    library: RefCell<store::Library>,
    choice: RefCell<Choice>,
    overrides: RefCell<Style>,
    look: RefCell<Rc<Look>>,
    user_appearance: RefCell<String>,
    artwork_seed: RefCell<Option<Rgb>>,
    accent: Cell<Rgb>,
    listeners: RefCell<Vec<Box<dyn Fn() -> bool>>>,
    on_look_changed: Box<dyn Fn()>,
    last_css: RefCell<String>,
    last_look_css: RefCell<Option<String>>,
    refresh_pending: Cell<bool>,
    deferred_while_suspended: Cell<bool>,
    stylesheet_errors: Rc<RefCell<Vec<String>>>,
    generated_lines: Rc<Cell<usize>>,
    monitors: RefCell<Vec<gio::FileMonitor>>,
    watched: RefCell<Vec<PathBuf>>,
    reload_pending: Cell<bool>,
    fonts_added: RefCell<HashSet<PathBuf>>,
    font_worn: RefCell<Option<Option<String>>>,
}

/// The current accent as normalized 0..1 RGB, for Cairo-drawn surfaces (stats
/// heatmap, listening clock) that can't read CSS named colors. Falls back to a
/// neutral blue before the controller is installed.
pub fn accent_tint() -> (f64, f64, f64) {
    let (r, g, b) = ThemeController::current()
        .map(|c| c.accent.get())
        .unwrap_or((0x5b, 0x9d, 0xf5));
    (r as f64 / 255.0, g as f64 / 255.0, b as f64 / 255.0)
}

thread_local! {
    static CONTROLLER: RefCell<Option<Rc<ThemeController>>> = const { RefCell::new(None) };
}

fn provider_at(priority_above_application: u32) -> gtk::CssProvider {
    let provider = gtk::CssProvider::new();
    if let Some(display) = gdk::Display::default() {
        gtk::style_context_add_provider_for_display(
            &display,
            &provider,
            gtk::STYLE_PROVIDER_PRIORITY_APPLICATION + priority_above_application,
        );
    }
    provider
}

impl ThemeController {
    /// Installs the providers above the base stylesheet, so the palette's
    /// `@define-color` and the theme's rules win, reads every theme there is
    /// and puts on the one `config` names. `on_look_changed` runs whenever the
    /// look itself changes (not on a mere retint), for the pages that are laid
    /// out by it.
    pub fn install(config: &Config, on_look_changed: impl Fn() + 'static) -> Rc<ThemeController> {
        let themes_dir = themes_dir();
        let _ = std::fs::create_dir_all(&themes_dir);
        let library = store::load(&themes_dir);
        let choice = Choice::from_config(config);
        let overrides = look::overrides_from_config(config);
        let look = Rc::new(Look::resolve(
            &library.find(&choice.pack),
            &choice,
            &overrides,
        ));

        let controller = Rc::new(ThemeController {
            palette_provider: provider_at(1),
            look_provider: provider_at(2),
            themes_dir,
            library: RefCell::new(library),
            choice: RefCell::new(choice),
            overrides: RefCell::new(overrides),
            look: RefCell::new(look),
            user_appearance: RefCell::new(config.appearance.clone()),
            artwork_seed: RefCell::new(None),
            accent: Cell::new((0x5b, 0x9d, 0xf5)),
            listeners: RefCell::new(Vec::new()),
            on_look_changed: Box::new(on_look_changed),
            last_css: RefCell::new(String::new()),
            last_look_css: RefCell::new(None),
            refresh_pending: Cell::new(false),
            deferred_while_suspended: Cell::new(false),
            stylesheet_errors: Rc::new(RefCell::new(Vec::new())),
            generated_lines: Rc::new(Cell::new(0)),
            monitors: RefCell::new(Vec::new()),
            watched: RefCell::new(Vec::new()),
            reload_pending: Cell::new(false),
            fonts_added: RefCell::new(HashSet::new()),
            font_worn: RefCell::new(None),
        });
        controller.collect_stylesheet_errors();
        CONTROLLER.with(|slot| *slot.borrow_mut() = Some(Rc::clone(&controller)));
        controller.wear();
        controller.report_problems();

        let weak = Rc::downgrade(&controller);
        adw::StyleManager::default().connect_dark_notify(move |_| {
            if let Some(controller) = weak.upgrade() {
                controller.refresh();
            }
        });
        controller
    }

    pub fn current() -> Option<Rc<ThemeController>> {
        CONTROLLER.with(|slot| slot.borrow().clone())
    }

    /// The look the app wears now.
    pub fn look(&self) -> Rc<Look> {
        Rc::clone(&self.look.borrow())
    }

    pub fn packs(&self) -> Vec<Rc<Pack>> {
        self.library.borrow().packs.clone()
    }

    pub fn problems(&self) -> Vec<store::Problem> {
        self.library.borrow().problems.clone()
    }

    /// What GTK refused in the theme's own stylesheet, each with its line.
    pub fn stylesheet_errors(&self) -> Vec<String> {
        self.stylesheet_errors.borrow().clone()
    }

    pub fn themes_dir(&self) -> &Path {
        &self.themes_dir
    }

    /// `pack` as it would look with `scheme` on and nothing of the person's
    /// own laid over it, for the picker's previews.
    pub fn preview(pack: &Rc<Pack>, scheme: &str) -> Look {
        let choice = Choice {
            pack: pack.id.clone(),
            scheme: scheme.to_string(),
            variant: String::new(),
        };
        Look::resolve(pack, &choice, &Style::default())
    }

    /// Puts on what is chosen: the theme with its scheme and variant, and the
    /// person's own choices over it, in one pass.
    pub fn apply(&self, choice: Choice, overrides: Style) {
        if *self.choice.borrow() == choice && *self.overrides.borrow() == overrides {
            return;
        }
        *self.choice.borrow_mut() = choice;
        *self.overrides.borrow_mut() = overrides;
        self.wear();
    }

    /// The light, dark or system mode the person asked for. A theme drawn for
    /// one mode only keeps that mode while it is on.
    pub fn set_user_appearance(&self, appearance: &str) {
        *self.user_appearance.borrow_mut() = appearance.to_string();
        self.apply_mode(&self.look());
    }

    /// Writes a copy of the theme with `id` into the themes folder for the
    /// person to change, and returns the copy's id and folder.
    pub fn make_editable_copy(&self, id: &str) -> Result<(String, PathBuf), String> {
        let made = {
            let library = self.library.borrow();
            store::make_editable_copy(&library.find(id), &self.themes_dir, &library)
        };
        if made.is_ok() {
            self.reload();
        }
        made
    }

    /// Reads the themes folder again and puts the chosen theme back on as it
    /// is now, so a saved edit shows without a restart.
    pub fn reload(&self) {
        *self.library.borrow_mut() = store::load(&self.themes_dir);
        self.wear();
        self.report_problems();
    }

    /// The interface zoom changed, which a theme's own pixel font sizes follow.
    pub fn rescale(&self) {
        self.load_look_stylesheet(&self.look());
    }

    /// Feeds the dominant color of the now-playing artwork. Only takes effect
    /// under a scheme that follows artwork; remembered otherwise so switching
    /// back to one picks up the current track instantly.
    pub fn set_artwork_color(&self, color: Option<Rgb>) {
        *self.artwork_seed.borrow_mut() = color;
        if self.look().follows_artwork() {
            self.schedule_refresh();
        }
    }

    /// Applies the palette that was held back while the windows were suspended.
    pub fn resume(&self) {
        if self.deferred_while_suspended.get() {
            self.refresh();
        }
    }

    /// Registers a widget to be notified (self-pruning on drop) whenever the
    /// palette changes, so Cairo-drawn surfaces can `queue_draw` to pick up the
    /// new accent — CSS-styled widgets retint on their own via the provider.
    pub fn connect_changed_widget<W: gtk::glib::object::ObjectType>(
        &self,
        widget: &W,
        callback: impl Fn(&W) + 'static,
    ) {
        let weak = gtk::glib::object::ObjectExt::downgrade(widget);
        self.listeners
            .borrow_mut()
            .push(Box::new(move || match weak.upgrade() {
                Some(widget) => {
                    callback(&widget);
                    true
                }
                None => false,
            }));
    }

    /// Resolves the look from what is chosen and applies every part of it:
    /// mode, corner scale, fonts, the theme's rules and stylesheet, then the
    /// palette. Ends by telling the pages that are laid out by the look.
    fn wear(&self) {
        let pack = self.library.borrow().find(&self.choice.borrow().pack);
        let look = Rc::new(Look::resolve(
            &pack,
            &self.choice.borrow(),
            &self.overrides.borrow(),
        ));
        *self.look.borrow_mut() = Rc::clone(&look);
        self.apply_mode(&look);
        crate::ui::ui_scale::set_corners(look.corners);
        self.apply_fonts(&look);
        self.load_look_stylesheet(&look);
        self.refresh();
        self.watch(&look);
        crate::logger::info(
            "theme",
            &format!(
                "wearing {} ({}{}), albums as {}, stylesheet problems: {}",
                look.pack.id,
                look.scheme().id,
                look.variant
                    .map(|index| format!(", {}", look.pack.variants[index].id))
                    .unwrap_or_default(),
                look.albums.id(),
                self.stylesheet_errors.borrow().len()
            ),
        );
        (self.on_look_changed)();
    }

    fn apply_mode(&self, look: &Look) {
        let scheme = match look.appearance() {
            Appearance::Dark => adw::ColorScheme::ForceDark,
            Appearance::Light => adw::ColorScheme::ForceLight,
            Appearance::Any => match self.user_appearance.borrow().as_str() {
                "light" => adw::ColorScheme::ForceLight,
                "dark" => adw::ColorScheme::ForceDark,
                _ => adw::ColorScheme::Default,
            },
        };
        adw::StyleManager::default().set_color_scheme(scheme);
    }

    /// Makes the theme's own font files known to Pango, then sets the
    /// interface font: the theme's or the person's, at the desktop font's
    /// size, or the desktop font itself when neither names one. The setting
    /// is left alone when the font is the one already worn, since writing it
    /// restyles every window.
    fn apply_fonts(&self, look: &Look) {
        for file in store::font_files(&look.pack) {
            if !self.fonts_added.borrow_mut().insert(file.clone()) {
                continue;
            }
            if let Err(error) = pangocairo::FontMap::default().add_font_file(&file) {
                crate::logger::warn(
                    "theme",
                    &format!("font {} could not be loaded: {error}", file.display()),
                );
            }
        }
        if self.font_worn.borrow().as_ref() == Some(&look.interface_font) {
            return;
        }
        let Some(settings) = gtk::Settings::default() else {
            return;
        };
        settings.reset_property("gtk-font-name");
        if let Some(families) = &look.interface_font {
            let desktop = settings
                .gtk_font_name()
                .map(|name| name.to_string())
                .unwrap_or_default();
            settings.set_gtk_font_name(Some(&css::font_setting(families, &desktop)));
        }
        *self.font_worn.borrow_mut() = Some(look.interface_font.clone());
    }

    fn collect_stylesheet_errors(&self) {
        let errors = Rc::clone(&self.stylesheet_errors);
        let generated_lines = Rc::clone(&self.generated_lines);
        self.look_provider
            .connect_parsing_error(move |_, section, error| {
                let line =
                    (section.start_location().lines() + 1).saturating_sub(generated_lines.get());
                errors.borrow_mut().push(format!(
                    "{} line {line}: {}",
                    store::STYLESHEET_NAME,
                    error.message()
                ));
            });
    }

    /// Loads the rules the look adds and the theme's own stylesheet, with its
    /// relative `url()`s pointed at the theme folder and its pixel font sizes
    /// following the interface zoom.
    fn load_look_stylesheet(&self, look: &Look) {
        let generated = css::look_css(look);
        let own = look
            .pack
            .css
            .as_deref()
            .map(|text| {
                let text = match &look.pack.dir {
                    Some(dir) => css::absolute_urls(text, dir),
                    None => text.to_string(),
                };
                crate::ui::ui_scale::scaled_stylesheet(&text, crate::ui::ui_scale::current())
            })
            .unwrap_or_default();
        let sheet = format!("{generated}{own}");
        if self.last_look_css.borrow().as_deref() == Some(sheet.as_str()) {
            return;
        }
        self.generated_lines.set(generated.lines().count());
        self.stylesheet_errors.borrow_mut().clear();
        self.look_provider.load_from_string(&sheet);
        *self.last_look_css.borrow_mut() = Some(sheet);
        let errors = self.stylesheet_errors.borrow();
        for error in errors.iter() {
            crate::logger::warn("theme", &format!("{}: {error}", look.pack.id));
        }
    }

    fn report_problems(&self) {
        let library = self.library.borrow();
        for problem in &library.problems {
            crate::logger::warn("theme", &format!("{}: {}", problem.folder, problem.reason));
        }
        for pack in &library.packs {
            for warning in &pack.warnings {
                crate::logger::warn("theme", &format!("{}: {warning}", pack.id));
            }
        }
    }

    /// Watches the themes folder and the folder of the theme that is on, so a
    /// theme dropped in appears and an edit to the worn one shows as it is
    /// saved.
    fn watch(&self, look: &Look) {
        let mut folders = vec![self.themes_dir.clone()];
        folders.extend(look.pack.dir.clone());
        if *self.watched.borrow() == folders {
            return;
        }
        let monitors = folders
            .iter()
            .filter_map(|folder| {
                let monitor = gio::File::for_path(folder)
                    .monitor_directory(gio::FileMonitorFlags::WATCH_MOVES, gio::Cancellable::NONE)
                    .ok()?;
                monitor.connect_changed(|_, _, _, event| {
                    if event == gio::FileMonitorEvent::Changed {
                        return;
                    }
                    if let Some(controller) = Self::current() {
                        controller.schedule_reload();
                    }
                });
                Some(monitor)
            })
            .collect();
        *self.monitors.borrow_mut() = monitors;
        *self.watched.borrow_mut() = folders;
    }

    fn schedule_reload(&self) {
        if self.reload_pending.replace(true) {
            return;
        }
        glib::timeout_add_local_once(FILES_SETTLE, || {
            if let Some(controller) = Self::current() {
                controller.reload_pending.set(false);
                controller.reload();
            }
        });
    }

    /// Coalesces rapid now-playing color changes (queue clicks, skips) into a
    /// single throttled reload, so a track change never blocks the main thread
    /// with an app-wide restyle. The reload also self-skips when the resolved
    /// palette is unchanged (same album, or fallback-to-fallback).
    fn schedule_refresh(&self) {
        if self.refresh_pending.replace(true) {
            return;
        }
        glib::timeout_add_local_once(PALETTE_SETTLE, || {
            if let Some(controller) = Self::current() {
                controller.refresh_pending.set(false);
                controller.refresh_if_visible();
            }
        });
    }

    /// Reloads the palette unless every window on screen is suspended: the
    /// compositor shows none of them, so the app-wide restyle would be paid for
    /// nothing. The latest palette is applied by `resume` when one comes back.
    fn refresh_if_visible(&self) {
        if all_windows_suspended() {
            self.deferred_while_suspended.set(true);
            return;
        }
        self.refresh();
    }

    fn refresh(&self) {
        self.deferred_while_suspended.set(false);
        let dark = adw::StyleManager::default().is_dark();
        let palette = self.look().palette(dark, *self.artwork_seed.borrow());
        let css = css::palette_css(&palette);
        if *self.last_css.borrow() == css {
            return;
        }
        *self.last_css.borrow_mut() = css.clone();
        self.accent.set(palette.accent_bg);
        self.palette_provider.load_from_string(&css);
        self.listeners.borrow_mut().retain(|listener| listener());
    }
}
