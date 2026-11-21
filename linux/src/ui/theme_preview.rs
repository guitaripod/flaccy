use crate::theme::color::{hsl_to_rgb, rgb_to_hsl, Hsl, Rgb};
use crate::theme::look::Palette;
use crate::theme::{AlbumsView, Appearance, CoverShape, Look, ThemeController};
use gtk::cairo;
use gtk::prelude::*;
use std::f64::consts::PI;

pub const WIDTH: i32 = 216;
pub const HEIGHT: i32 = 132;

const SIDEBAR: f64 = 50.0;
const TRANSPORT: f64 = 20.0;
const CONTENT_INSET: f64 = 10.0;

/// The hue steps, from the accent, the stand-in covers of a preview are
/// painted in, so a thumbnail reads as a shelf of different records.
const COVER_HUES: [f64; 8] = [0.0, 38.0, 196.0, 282.0, 122.0, 328.0, 78.0, 232.0];

/// Whether `look` is drawn dark here: its own mode when it insists on one,
/// otherwise the mode the app is in.
fn drawn_dark(look: &Look) -> bool {
    match look.appearance() {
        Appearance::Dark => true,
        Appearance::Light => false,
        Appearance::Any => adw::StyleManager::default().is_dark(),
    }
}

fn source(cr: &cairo::Context, color: Rgb, alpha: f64) {
    cr.set_source_rgba(
        color.0 as f64 / 255.0,
        color.1 as f64 / 255.0,
        color.2 as f64 / 255.0,
        alpha,
    );
}

fn rounded(cr: &cairo::Context, x: f64, y: f64, width: f64, height: f64, radius: f64) {
    let radius = radius.min(width / 2.0).min(height / 2.0).max(0.0);
    cr.new_sub_path();
    cr.arc(x + width - radius, y + radius, radius, -PI / 2.0, 0.0);
    cr.arc(
        x + width - radius,
        y + height - radius,
        radius,
        0.0,
        PI / 2.0,
    );
    cr.arc(x + radius, y + height - radius, radius, PI / 2.0, PI);
    cr.arc(x + radius, y + radius, radius, PI, 3.0 * PI / 2.0);
    cr.close_path();
}

fn bar(cr: &cairo::Context, color: Rgb, alpha: f64, x: f64, y: f64, width: f64) {
    source(cr, color, alpha);
    rounded(cr, x, y, width, 3.0, 1.5);
    let _ = cr.fill();
}

struct Painter<'a> {
    cr: &'a cairo::Context,
    look: &'a Look,
    palette: Palette,
    text: Rgb,
    dark: bool,
}

impl Painter<'_> {
    fn cover_color(&self, index: usize) -> Rgb {
        let accent = rgb_to_hsl(self.palette.accent_bg);
        hsl_to_rgb(Hsl {
            h: accent.h + COVER_HUES[index % COVER_HUES.len()],
            s: 0.42,
            l: if self.dark { 0.44 } else { 0.62 },
        })
    }

    fn cover(&self, index: usize, x: f64, y: f64, side: f64, alpha: f64) {
        let radius = match self.look.covers {
            CoverShape::Square => 0.0,
            CoverShape::Circle => side / 2.0,
            CoverShape::Rounded => side * 0.1 * self.look.corners,
        };
        source(self.cr, self.cover_color(index), alpha);
        rounded(self.cr, x, y, side, side, radius);
        let _ = self.cr.fill();
    }

    fn sidebar(&self, height: f64) {
        source(self.cr, self.palette.sidebar, 1.0);
        self.cr.rectangle(0.0, 0.0, SIDEBAR, height);
        let _ = self.cr.fill();
        for row in 0..5 {
            let y = 16.0 + row as f64 * 13.0;
            if row == 1 {
                source(self.cr, self.palette.accent_bg, 0.26);
                rounded(
                    self.cr,
                    6.0,
                    y - 4.5,
                    SIDEBAR - 12.0,
                    12.0,
                    3.0 * self.look.corners,
                );
                let _ = self.cr.fill();
                bar(self.cr, self.palette.accent_text, 1.0, 11.0, y, 24.0);
            } else {
                bar(
                    self.cr,
                    self.text,
                    0.34,
                    11.0,
                    y,
                    18.0 + (row % 3) as f64 * 5.0,
                );
            }
        }
    }

    fn transport(&self, width: f64, height: f64) {
        let top = height - TRANSPORT;
        source(self.cr, self.palette.headerbar, 1.0);
        self.cr.rectangle(0.0, top, width, TRANSPORT);
        let _ = self.cr.fill();
        bar(self.cr, self.text, 0.18, 64.0, top + 14.0, width - 76.0);
        bar(
            self.cr,
            self.palette.accent_bg,
            1.0,
            64.0,
            top + 14.0,
            (width - 76.0) * 0.38,
        );
        source(self.cr, self.palette.accent_bg, 1.0);
        self.cr.arc(
            width / 2.0 + SIDEBAR / 2.0 - 12.0,
            top + 7.0,
            4.0,
            0.0,
            2.0 * PI,
        );
        let _ = self.cr.fill();
        bar(self.cr, self.text, 0.5, 8.0, top + 6.0, 28.0);
        bar(self.cr, self.text, 0.26, 8.0, top + 12.0, 18.0);
    }

    fn glow(&self, width: f64, height: f64) {
        if !self.look.glow {
            return;
        }
        let wash = self.palette.wash_a;
        let gradient =
            cairo::RadialGradient::new(SIDEBAR + 20.0, 0.0, 0.0, SIDEBAR + 20.0, 0.0, width * 0.7);
        let channel = |value: u8| value as f64 / 255.0;
        gradient.add_color_stop_rgba(0.0, channel(wash.0), channel(wash.1), channel(wash.2), 0.75);
        gradient.add_color_stop_rgba(1.0, channel(wash.0), channel(wash.1), channel(wash.2), 0.0);
        let _ = self.cr.set_source(&gradient);
        self.cr.rectangle(0.0, 0.0, width, height);
        let _ = self.cr.fill();
    }

    fn grid(&self, x: f64, y: f64, width: f64) {
        let gap = 9.0;
        let side = (width - gap * 3.0) / 4.0;
        for index in 0..8 {
            let column = (index % 4) as f64;
            let row = (index / 4) as f64;
            let left = x + column * (side + gap);
            let top = y + row * (side + 15.0);
            self.cover(index, left, top, side, 1.0);
            bar(self.cr, self.text, 0.5, left, top + side + 4.0, side * 0.8);
            bar(self.cr, self.text, 0.24, left, top + side + 9.0, side * 0.5);
        }
    }

    fn wall(&self, width: f64, height: f64) {
        let side = (width - SIDEBAR) / 4.0;
        let rows = ((height - TRANSPORT) / side).ceil() as usize;
        for index in 0..rows * 4 {
            let left = SIDEBAR + (index % 4) as f64 * side;
            let top = (index / 4) as f64 * side;
            source(self.cr, self.cover_color(index), 1.0);
            self.cr.rectangle(left, top, side + 0.5, side + 0.5);
            let _ = self.cr.fill();
        }
    }

    fn list(&self, x: f64, y: f64, width: f64) {
        let rows_width = width * 0.5;
        for row in 0..6 {
            let top = y + row as f64 * 13.5;
            if row == 1 {
                source(self.cr, self.palette.accent_bg, 0.22);
                rounded(
                    self.cr,
                    x - 3.0,
                    top - 2.5,
                    rows_width,
                    13.0,
                    2.5 * self.look.corners,
                );
                let _ = self.cr.fill();
            }
            self.cover(row, x, top, 8.0, 1.0);
            bar(
                self.cr,
                self.text,
                if row == 1 { 0.9 } else { 0.5 },
                x + 13.0,
                top + 1.0,
                30.0 + (row % 3) as f64 * 9.0,
            );
            bar(self.cr, self.text, 0.22, x + 13.0, top + 5.5, 22.0);
        }
        let side = width * 0.36;
        let left = x + width - side - 2.0;
        self.cover(1, left, y, side, 1.0);
        bar(self.cr, self.text, 0.7, left, y + side + 6.0, side * 0.9);
        bar(self.cr, self.text, 0.3, left, y + side + 12.0, side * 0.6);
        bar(
            self.cr,
            self.palette.accent_bg,
            1.0,
            left,
            y + side + 20.0,
            side * 0.42,
        );
    }

    fn carousel(&self, x: f64, y: f64, width: f64) {
        let centre = x + width / 2.0;
        let big = 56.0;
        for (index, (offset, side, alpha)) in [
            (-78.0, 26.0, 0.45),
            (78.0, 26.0, 0.45),
            (-46.0, 36.0, 0.8),
            (46.0, 36.0, 0.8),
        ]
        .into_iter()
        .enumerate()
        {
            self.cover(
                index + 2,
                centre + offset - side / 2.0,
                y + (big - side) / 2.0 + 2.0,
                side,
                alpha,
            );
        }
        self.cover(0, centre - big / 2.0, y + 2.0, big, 1.0);
        bar(
            self.cr,
            self.text,
            0.75,
            centre - 30.0,
            y + big + 10.0,
            60.0,
        );
        bar(self.cr, self.text, 0.3, centre - 19.0, y + big + 16.0, 38.0);
    }

    fn paint(&self, width: f64, height: f64) {
        rounded(
            self.cr,
            0.0,
            0.0,
            width,
            height,
            10.0 * self.look.corners.min(1.6),
        );
        self.cr.clip();
        source(self.cr, self.palette.window, 1.0);
        let _ = self.cr.paint();
        self.glow(width, height);
        let content_x = SIDEBAR + CONTENT_INSET;
        let content_width = width - content_x - CONTENT_INSET;
        match self.look.albums {
            AlbumsView::Grid => self.grid(content_x, CONTENT_INSET, content_width),
            AlbumsView::Wall => self.wall(width, height),
            AlbumsView::List => self.list(content_x, CONTENT_INSET + 2.0, content_width),
            AlbumsView::Carousel => self.carousel(content_x, CONTENT_INSET + 4.0, content_width),
        }
        self.sidebar(height);
        self.transport(width, height);
    }
}

/// Paints the preview in its own 216 by 132 space, scaled to the room given.
fn paint(cr: &cairo::Context, width: f64, height: f64, look: &Look) {
    cr.scale(width / WIDTH as f64, height / HEIGHT as f64);
    let (width, height) = (WIDTH as f64, HEIGHT as f64);
    let dark = drawn_dark(look);
    let palette = look.palette(dark, None);
    let text = palette.text.unwrap_or(if dark {
        (0xff, 0xff, 0xff)
    } else {
        (0x1e, 0x1e, 0x20)
    });
    Painter {
        cr,
        look,
        palette,
        text,
        dark,
    }
    .paint(width, height);
}

/// A small drawing of the app as `look` would dress it: its colors, its cover
/// shape and corners, and how it lays the albums out. Drawn from the look
/// itself, so a theme somebody made yesterday has one without shipping a
/// picture.
pub fn thumbnail(look: Look) -> gtk::DrawingArea {
    let area = gtk::DrawingArea::builder()
        .content_width(WIDTH)
        .content_height(HEIGHT)
        .build();
    area.set_draw_func(move |_, cr, width, height| paint(cr, width as f64, height as f64, &look));
    if let Some(controller) = ThemeController::current() {
        controller.connect_changed_widget(&area, |area| area.queue_draw());
    }
    area
}

/// A dot in a scheme's accent, for the row that chooses between schemes.
pub fn swatch(look: Look) -> gtk::DrawingArea {
    let area = gtk::DrawingArea::builder()
        .content_width(22)
        .content_height(22)
        .valign(gtk::Align::Center)
        .build();
    area.set_draw_func(move |_, cr, width, height| {
        let palette = look.palette(drawn_dark(&look), None);
        let (width, height) = (width as f64, height as f64);
        source(cr, palette.window, 1.0);
        cr.arc(width / 2.0, height / 2.0, width / 2.0, 0.0, 2.0 * PI);
        let _ = cr.fill();
        source(cr, palette.accent_bg, 1.0);
        cr.arc(width / 2.0, height / 2.0, width / 2.0 - 4.0, 0.0, 2.0 * PI);
        let _ = cr.fill();
    });
    area
}
