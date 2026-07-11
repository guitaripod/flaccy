use gtk::gdk;
use gtk::glib;
use std::cell::{Cell, RefCell};
use std::rc::Rc;
use std::time::Duration;

/// The palette the app is currently tinted with. Fixed presets carry a seed
/// hue; `Adaptive` follows the now-playing artwork's dominant color.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Theme {
    Adaptive,
    Rosewater,
    Aurora,
    Nocturne,
    Verdant,
    Sunset,
    Mono,
}

impl Theme {
    pub const ALL: [Theme; 7] = [
        Theme::Adaptive,
        Theme::Rosewater,
        Theme::Aurora,
        Theme::Nocturne,
        Theme::Verdant,
        Theme::Sunset,
        Theme::Mono,
    ];

    pub fn id(self) -> &'static str {
        match self {
            Theme::Adaptive => "adaptive",
            Theme::Rosewater => "rosewater",
            Theme::Aurora => "aurora",
            Theme::Nocturne => "nocturne",
            Theme::Verdant => "verdant",
            Theme::Sunset => "sunset",
            Theme::Mono => "mono",
        }
    }

    pub fn from_id(id: &str) -> Theme {
        match id {
            "rosewater" => Theme::Rosewater,
            "aurora" => Theme::Aurora,
            "nocturne" => Theme::Nocturne,
            "verdant" => Theme::Verdant,
            "sunset" => Theme::Sunset,
            "mono" => Theme::Mono,
            _ => Theme::Adaptive,
        }
    }

    pub fn title(self) -> &'static str {
        match self {
            Theme::Adaptive => "Adaptive",
            Theme::Rosewater => "Rosewater",
            Theme::Aurora => "Aurora",
            Theme::Nocturne => "Nocturne",
            Theme::Verdant => "Verdant",
            Theme::Sunset => "Sunset",
            Theme::Mono => "Mono",
        }
    }

    pub fn subtitle(self) -> &'static str {
        match self {
            Theme::Adaptive => "Follows the album you're playing",
            Theme::Rosewater => "Warm rose",
            Theme::Aurora => "Teal into violet",
            Theme::Nocturne => "Deep indigo",
            Theme::Verdant => "Forest green",
            Theme::Sunset => "Amber into flame",
            Theme::Mono => "Restrained graphite",
        }
    }

    /// Seed color for fixed presets; Adaptive falls back to this when nothing
    /// is playing yet (the brand rose).
    fn seed(self) -> (u8, u8, u8) {
        match self {
            Theme::Adaptive | Theme::Rosewater => (0xFF, 0x4D, 0x6D),
            Theme::Aurora => (0x2D, 0xD4, 0xBF),
            Theme::Nocturne => (0x6E, 0x8B, 0xFF),
            Theme::Verdant => (0x34, 0xD3, 0x99),
            Theme::Sunset => (0xFB, 0x8B, 0x24),
            Theme::Mono => (0x9C, 0xA3, 0xAF),
        }
    }

    fn follows_artwork(self) -> bool {
        matches!(self, Theme::Adaptive)
    }
}

#[derive(Clone, Copy)]
struct Hsl {
    h: f64,
    s: f64,
    l: f64,
}

fn rgb_to_hsl(r: u8, g: u8, b: u8) -> Hsl {
    let r = r as f64 / 255.0;
    let g = g as f64 / 255.0;
    let b = b as f64 / 255.0;
    let max = r.max(g).max(b);
    let min = r.min(g).min(b);
    let l = (max + min) / 2.0;
    let delta = max - min;
    if delta < 1e-6 {
        return Hsl { h: 0.0, s: 0.0, l };
    }
    let s = delta / (1.0 - (2.0 * l - 1.0).abs());
    let h = if max == r {
        60.0 * (((g - b) / delta).rem_euclid(6.0))
    } else if max == g {
        60.0 * (((b - r) / delta) + 2.0)
    } else {
        60.0 * (((r - g) / delta) + 4.0)
    };
    Hsl { h, s, l }
}

fn hsl_to_rgb(hsl: Hsl) -> (u8, u8, u8) {
    let Hsl { h, s, l } = hsl;
    let c = (1.0 - (2.0 * l - 1.0).abs()) * s;
    let hp = (h.rem_euclid(360.0)) / 60.0;
    let x = c * (1.0 - (hp.rem_euclid(2.0) - 1.0).abs());
    let (r1, g1, b1) = match hp as i32 {
        0 => (c, x, 0.0),
        1 => (x, c, 0.0),
        2 => (0.0, c, x),
        3 => (0.0, x, c),
        4 => (x, 0.0, c),
        _ => (c, 0.0, x),
    };
    let m = l - c / 2.0;
    (
        (((r1 + m) * 255.0).round()).clamp(0.0, 255.0) as u8,
        (((g1 + m) * 255.0).round()).clamp(0.0, 255.0) as u8,
        (((b1 + m) * 255.0).round()).clamp(0.0, 255.0) as u8,
    )
}

fn hex(rgb: (u8, u8, u8)) -> String {
    format!("#{:02x}{:02x}{:02x}", rgb.0, rgb.1, rgb.2)
}

/// Relative luminance for choosing a legible on-accent foreground.
fn luminance(rgb: (u8, u8, u8)) -> f64 {
    let channel = |c: u8| {
        let c = c as f64 / 255.0;
        if c <= 0.03928 {
            c / 12.92
        } else {
            ((c + 0.055) / 1.055).powf(2.4)
        }
    };
    0.2126 * channel(rgb.0) + 0.7152 * channel(rgb.1) + 0.0722 * channel(rgb.2)
}

/// The resolved set of colors a palette expands into for a given light/dark
/// mode. Album artwork often yields muddy or blown-out colors, so the hue is
/// preserved while saturation and lightness are pulled into a legible,
/// vivid band.
struct Palette {
    accent_bg: (u8, u8, u8),
    accent_fg: (u8, u8, u8),
    accent_text: (u8, u8, u8),
    wash_a: (u8, u8, u8),
    wash_b: (u8, u8, u8),
    surface: (u8, u8, u8),
    window: (u8, u8, u8),
    headerbar: (u8, u8, u8),
    sidebar: (u8, u8, u8),
    view: (u8, u8, u8),
}

fn resolve(seed: (u8, u8, u8), mono: bool, dark: bool) -> Palette {
    let base = rgb_to_hsl(seed.0, seed.1, seed.2);
    let hue = base.h;
    let sat = if mono {
        (base.s * 0.35).clamp(0.0, 0.18)
    } else {
        base.s.clamp(0.55, 0.92)
    };

    let accent_bg = hsl_to_rgb(Hsl {
        h: hue,
        s: sat,
        l: if dark { 0.56 } else { 0.50 },
    });
    let accent_fg = if luminance(accent_bg) > 0.55 {
        (0x11, 0x11, 0x14)
    } else {
        (0xff, 0xff, 0xff)
    };
    let accent_text = hsl_to_rgb(Hsl {
        h: hue,
        s: (sat + 0.05).min(0.95),
        l: if dark { 0.72 } else { 0.42 },
    });

    let tint = |s_mul: f64, s_cap: f64, l: f64, h_shift: f64| {
        hsl_to_rgb(Hsl {
            h: (hue + h_shift).rem_euclid(360.0),
            s: (sat * s_mul).min(s_cap),
            l,
        })
    };

    let (wash_a, wash_b, surface, window, headerbar, sidebar, view) = if dark {
        (
            tint(0.9, 0.85, 0.20, 0.0),
            tint(0.85, 0.80, 0.11, 28.0),
            tint(0.40, 0.35, 0.145, 0.0),
            tint(0.35, 0.28, 0.082, 0.0),
            tint(0.35, 0.26, 0.118, 0.0),
            tint(0.35, 0.26, 0.10, 0.0),
            tint(0.30, 0.22, 0.105, 0.0),
        )
    } else {
        (
            tint(0.70, 0.60, 0.93, 0.0),
            tint(0.60, 0.50, 0.97, 28.0),
            tint(0.30, 0.22, 0.985, 0.0),
            tint(0.28, 0.18, 0.965, 0.0),
            tint(0.26, 0.16, 0.982, 0.0),
            tint(0.30, 0.20, 0.955, 0.0),
            tint(0.20, 0.14, 0.995, 0.0),
        )
    };

    Palette {
        accent_bg,
        accent_fg,
        accent_text,
        wash_a,
        wash_b,
        surface,
        window,
        headerbar,
        sidebar,
        view,
    }
}

/// Builds the runtime CSS that redefines libadwaita's accent colors plus the
/// custom `flaccy_*` colors the static stylesheet references. Swapping this in
/// live retints the entire app; widgets that opt into transitions cross-fade.
fn generate_css(p: &Palette) -> String {
    format!(
        "@define-color accent_bg_color {accent_bg};\n\
         @define-color accent_color {accent_text};\n\
         @define-color accent_fg_color {accent_fg};\n\
         @define-color flaccy_accent {accent_bg};\n\
         @define-color flaccy_accent_text {accent_text};\n\
         @define-color flaccy_wash_a {wash_a};\n\
         @define-color flaccy_wash_b {wash_b};\n\
         @define-color flaccy_surface {surface};\n\
         @define-color window_bg_color {window};\n\
         @define-color view_bg_color {view};\n\
         @define-color headerbar_bg_color {headerbar};\n\
         @define-color sidebar_bg_color {sidebar};\n\
         @define-color card_bg_color {surface};\n\
         @define-color popover_bg_color {headerbar};\n\
         @define-color dialog_bg_color {headerbar};\n",
        accent_bg = hex(p.accent_bg),
        accent_text = hex(p.accent_text),
        accent_fg = hex(p.accent_fg),
        wash_a = hex(p.wash_a),
        wash_b = hex(p.wash_b),
        surface = hex(p.surface),
        window = hex(p.window),
        view = hex(p.view),
        headerbar = hex(p.headerbar),
        sidebar = hex(p.sidebar),
    )
}

/// Owns the swappable CSS provider that carries the live palette. A single
/// provider is reloaded on every change so providers never stack.
pub struct ThemeController {
    provider: gtk::CssProvider,
    theme: Cell<Theme>,
    artwork_seed: RefCell<Option<(u8, u8, u8)>>,
    accent: Cell<(u8, u8, u8)>,
    listeners: RefCell<Vec<Box<dyn Fn() -> bool>>>,
    last_css: RefCell<String>,
    refresh_pending: Cell<bool>,
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

impl ThemeController {
    /// Installs the provider (above the base stylesheet so its `@define-color`
    /// wins) and wires a dark-mode listener so the palette re-resolves when the
    /// system flips light/dark.
    pub fn install(initial: Theme) -> Rc<ThemeController> {
        let provider = gtk::CssProvider::new();
        if let Some(display) = gdk::Display::default() {
            gtk::style_context_add_provider_for_display(
                &display,
                &provider,
                gtk::STYLE_PROVIDER_PRIORITY_APPLICATION + 1,
            );
        }
        let controller = Rc::new(ThemeController {
            provider,
            theme: Cell::new(initial),
            artwork_seed: RefCell::new(None),
            accent: Cell::new((0x5b, 0x9d, 0xf5)),
            listeners: RefCell::new(Vec::new()),
            last_css: RefCell::new(String::new()),
            refresh_pending: Cell::new(false),
        });
        controller.refresh();

        {
            let weak = Rc::downgrade(&controller);
            adw::StyleManager::default().connect_dark_notify(move |_| {
                if let Some(controller) = weak.upgrade() {
                    controller.refresh();
                }
            });
        }

        CONTROLLER.with(|slot| *slot.borrow_mut() = Some(Rc::clone(&controller)));
        controller
    }

    pub fn current() -> Option<Rc<ThemeController>> {
        CONTROLLER.with(|slot| slot.borrow().clone())
    }

    pub fn set_theme(&self, theme: Theme) {
        self.theme.set(theme);
        self.refresh();
    }

    /// Feeds the dominant color of the now-playing artwork. Only takes effect
    /// under the Adaptive theme; ignored (but remembered) otherwise so toggling
    /// back to Adaptive picks up the current track instantly.
    pub fn set_artwork_color(&self, color: Option<(u8, u8, u8)>) {
        *self.artwork_seed.borrow_mut() = color;
        if self.theme.get().follows_artwork() {
            self.schedule_refresh();
        }
    }

    /// Coalesces rapid now-playing color changes (queue clicks, skips) into a
    /// single throttled reload, so a track change never blocks the main thread
    /// with an app-wide restyle. The reload also self-skips when the resolved
    /// palette is unchanged (same album, or fallback-to-fallback).
    fn schedule_refresh(&self) {
        if self.refresh_pending.replace(true) {
            return;
        }
        glib::timeout_add_local_once(Duration::from_millis(180), || {
            if let Some(controller) = Self::current() {
                controller.refresh_pending.set(false);
                controller.refresh();
            }
        });
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

    fn seed(&self) -> (u8, u8, u8) {
        let theme = self.theme.get();
        if theme.follows_artwork() {
            self.artwork_seed
                .borrow()
                .unwrap_or_else(|| theme.seed())
        } else {
            theme.seed()
        }
    }

    fn refresh(&self) {
        let theme = self.theme.get();
        let dark = adw::StyleManager::default().is_dark();
        let palette = resolve(self.seed(), theme == Theme::Mono, dark);
        let css = generate_css(&palette);
        if *self.last_css.borrow() == css {
            return;
        }
        *self.last_css.borrow_mut() = css.clone();
        self.accent.set(palette.accent_bg);
        self.provider.load_from_string(&css);
        self.listeners.borrow_mut().retain(|listener| listener());
    }
}
