//! Paints one frame of a lyric clip, or its still card, with Cairo and Pango.
//! Mirrors `Features/LyricShare/LyricShareRenderer.swift` drawing for drawing:
//! the same layout, motion, palette and visualizer from `flaccy_shared`, the
//! same constants below. Everything that does not move is drawn once into a
//! base surface.

use super::{Cover, Scene};
use cairo::{Context, Format, ImageSurface, LinearGradient, RadialGradient};
use flaccy_shared::lyric_share::{
    self as share, Alignment, Color, Focus, Layout, Rect, Template, Typeface,
};
use flaccy_shared::lyrics::{Line, LineProgress};
use gtk::pango;
use std::f64::consts::PI;

/// How wide the blurred backdrop is before it is stretched over the canvas,
/// and how soft its blur is at that size.
pub const BACKDROP_WIDTH: i32 = 72;
pub const BACKDROP_SIGMA: f32 = 5.0;
/// How strongly the deep background colour is laid over the backdrop.
pub const BACKDROP_SHADE: f64 = 0.45;
/// Where a verse keeps the line being sung, as a share of the lyrics box from
/// its top, and how far from either edge lines fade out.
pub const VERSE_ANCHOR: f64 = 0.34;
pub const VERSE_FADE: f64 = 120.0;
/// The gap between stacked lines, in lyric sizes.
pub const STACK_GAP: f64 = 0.42;
/// The soft edge of the word fill, in canvas pixels.
pub const FILL_SOFTNESS: f64 = 14.0;
/// How fast the pulse disc turns, in radians a second.
pub const DISC_SPIN: f64 = 0.12;
/// The distance between rows of a wrapped line, in lyric sizes.
pub const LINE_SPACING: f64 = 1.14;
/// How many columns the poster's waveform has.
const WAVE_COLUMNS: usize = 96;
/// How many steps the soft fill edge is drawn in.
const FILL_SLICES: usize = 4;

#[derive(Clone, Copy, PartialEq)]
enum Weight {
    Lyric,
    Title,
    Artist,
    Mark,
}

fn font(typeface: Typeface, weight: Weight, size: f64) -> pango::FontDescription {
    let face = if weight == Weight::Mark { Typeface::Modern } else { typeface };
    let family = match face {
        Typeface::Modern => "Inter Display, Inter, Cantarell, Adwaita Sans, Noto Sans, sans-serif",
        Typeface::Serif => "Noto Serif Display, Noto Serif, DejaVu Serif, Liberation Serif, serif",
        Typeface::Rounded => "Nunito, Quicksand, Varela Round, Comfortaa, Adwaita Sans, sans-serif",
        Typeface::Mono => "JetBrains Mono, Adwaita Mono, Fira Code, DejaVu Sans Mono, monospace",
    };
    let weight = match weight {
        Weight::Lyric if face == Typeface::Mono => pango::Weight::Bold,
        Weight::Lyric | Weight::Mark => pango::Weight::Heavy,
        Weight::Title => pango::Weight::Bold,
        Weight::Artist => pango::Weight::Medium,
    };
    let mut description = pango::FontDescription::new();
    description.set_family(family);
    description.set_weight(weight);
    description.set_absolute_size(size * pango::SCALE as f64);
    description
}

/// A run of text broken into rows that fit a width, placed for its
/// alignment. Coordinates are y-down from the block's top left.
struct TextBlock {
    layout: pango::Layout,
    height: f64,
    font_size: f64,
    rtl: bool,
    rows: Vec<(f64, f64, f64, f64)>,
}

impl TextBlock {
    fn new(
        context: &pango::Context,
        text: &str,
        typeface: Typeface,
        size: f64,
        width: f64,
        alignment: Alignment,
    ) -> Self {
        let description = font(typeface, Weight::Lyric, size);
        let layout = pango::Layout::new(context);
        layout.set_font_description(Some(&description));
        layout.set_auto_dir(true);
        layout.set_wrap(pango::WrapMode::WordChar);
        layout.set_width((width * pango::SCALE as f64) as i32);
        layout.set_alignment(match alignment {
            Alignment::Center => pango::Alignment::Center,
            Alignment::Leading => pango::Alignment::Left,
        });
        let metrics = context.metrics(Some(&description), None);
        let natural = metrics.height() as f64 / pango::SCALE as f64;
        if natural > 0.0 {
            layout.set_line_spacing((LINE_SPACING * size / natural) as f32);
        }
        layout.set_text(text);
        let rtl = layout
            .line_readonly(0)
            .is_some_and(|line| line.resolved_direction() == pango::Direction::Rtl);
        if rtl && alignment == Alignment::Leading {
            layout.set_alignment(pango::Alignment::Right);
        }
        let scale = pango::SCALE as f64;
        let mut rows = Vec::new();
        let mut iter = layout.iter();
        loop {
            let (_, logical) = iter.line_extents();
            rows.push((
                logical.x() as f64 / scale,
                logical.y() as f64 / scale,
                logical.width() as f64 / scale,
                logical.height() as f64 / scale,
            ));
            if !iter.next_line() {
                break;
            }
        }
        let height = layout.size().1 as f64 / scale;
        Self {
            layout,
            height,
            font_size: size,
            rtl,
            rows,
        }
    }

    fn draw(&self, cr: &Context, x: f64, y: f64) {
        cr.move_to(x, y);
        pangocairo::functions::show_layout(cr, &self.layout);
    }

    /// The row holding a byte offset into the text and the x of that offset.
    fn position(&self, byte: usize) -> (usize, f64) {
        let (line, x) = self.layout.index_to_line_x(byte as i32, false);
        let row = (line.max(0) as usize).min(self.rows.len().saturating_sub(1));
        (row, self.rows[row].0 + x as f64 / pango::SCALE as f64)
    }
}

/// Fits `text` in `bounds` at `size`, shrinking until it does or reaches the
/// smallest size a template allows.
fn fitting(
    context: &pango::Context,
    text: &str,
    typeface: Typeface,
    size: f64,
    bounds: (f64, f64),
    alignment: Alignment,
) -> TextBlock {
    let smallest = size * share::MINIMUM_LYRIC_SCALE;
    let mut current = size;
    loop {
        let block = TextBlock::new(context, text, typeface, current, bounds.0, alignment);
        if block.height <= bounds.1 || current <= smallest {
            return block;
        }
        current = (current * 0.92).max(smallest);
    }
}

pub struct Renderer {
    scene: Scene,
    layout: Layout,
    scale: f64,
    pub width: i32,
    pub height: i32,
    sung: Vec<usize>,
    texts: Vec<String>,
    context: pango::Context,
    cover: Option<ImageSurface>,
    base: Option<ImageSurface>,
    single: Option<Vec<TextBlock>>,
    verse: Option<Vec<TextBlock>>,
    stack: Option<Vec<TextBlock>>,
    loudest: usize,
}

impl Renderer {
    /// `scale` is output pixels per canvas pixel: 1 for the export, less for
    /// the preview.
    pub fn new(scene: Scene, scale: f64) -> Self {
        let style = scene.style;
        let layout = Layout::make(
            style.format,
            style.template,
            style.show_artwork,
            style.show_visualizer,
        );
        let width = ((layout.width * scale).round() as i32).max(1);
        let height = ((layout.height * scale).round() as i32).max(1);
        let (sung, texts) = match &scene.plain_lines {
            Some(plain) => {
                let sung: Vec<usize> = (scene.selection.first..=scene.selection.last).collect();
                let texts = sung.iter().map(|&index| plain[index].clone()).collect();
                (sung, texts)
            }
            None => {
                let sung = share::lines_of(scene.selection, &scene.document);
                let texts = sung
                    .iter()
                    .map(|&index| scene.document.lines[index].text.clone())
                    .collect();
                (sung, texts)
            }
        };
        let font_map = pangocairo::FontMap::new();
        let context = pango::prelude::FontMapExt::create_context(&font_map);
        let mut options = cairo::FontOptions::new().ok();
        if let Some(options) = options.as_mut() {
            options.set_antialias(cairo::Antialias::Gray);
            options.set_hint_style(cairo::HintStyle::None);
            options.set_hint_metrics(cairo::HintMetrics::Off);
        }
        pangocairo::functions::context_set_font_options(&context, options.as_ref());
        let cover = scene.cover.as_ref().and_then(|cover| surface_from(cover));
        let levels = &scene.analysis.levels;
        let loudest = (0..levels.len())
            .max_by(|&a, &b| levels[a].total_cmp(&levels[b]))
            .unwrap_or(0);
        Self {
            scene,
            layout,
            scale,
            width,
            height,
            sung,
            texts,
            context,
            cover,
            base: None,
            single: None,
            verse: None,
            stack: None,
            loudest,
        }
    }

    /// A surface of the renderer's size holding the frame, or the still card
    /// for `None`.
    pub fn image(&mut self, frame: Option<usize>) -> Option<ImageSurface> {
        let surface = ImageSurface::create(Format::ARgb32, self.width, self.height).ok()?;
        {
            let cr = Context::new(&surface).ok()?;
            self.render(frame, &cr);
        }
        surface.flush();
        Some(surface)
    }

    /// Paints a frame into a context whose user space is the renderer's
    /// pixels.
    pub fn render(&mut self, frame: Option<usize>, cr: &Context) {
        if self.base.is_none() {
            self.base = self.make_base();
        }
        let _ = cr.save();
        cr.scale(self.scale, self.scale);
        if let Some(base) = &self.base {
            let _ = cr.save();
            cr.scale(1.0 / self.scale, 1.0 / self.scale);
            let _ = cr.set_source_surface(base, 0.0, 0.0);
            let _ = cr.paint();
            let _ = cr.restore();
        }
        let time = frame.map(|frame| share::time_of_frame(frame, &self.scene.window));
        let visual = frame.unwrap_or(self.loudest);
        self.draw_visualizer(visual, frame, cr);
        if self.scene.style.template == Template::Pulse {
            self.draw_disc(visual, cr);
        }
        match time {
            Some(time) if self.scene.is_timed() => match self.scene.style.template {
                Template::Spotlight | Template::Pulse => self.draw_single(time, cr),
                Template::Verse => self.draw_verse(time, cr),
                Template::Poster => self.draw_stack(Some(time), cr),
            },
            _ => self.draw_stack(None, cr),
        }
        let _ = cr.restore();
    }

    fn make_base(&mut self) -> Option<ImageSurface> {
        let surface = ImageSurface::create(Format::ARgb32, self.width, self.height).ok()?;
        {
            let cr = Context::new(&surface).ok()?;
            cr.scale(self.scale, self.scale);
            self.draw_background(&cr);
            self.draw_header(&cr);
            self.draw_mark(&cr);
            if self.scene.style.template != Template::Pulse {
                if let Some(rect) = self.layout.artwork {
                    self.draw_cover(rect, self.layout.artwork_radius, &cr);
                }
            }
        }
        surface.flush();
        Some(surface)
    }

    fn draw_background(&self, cr: &Context) {
        let palette = &self.scene.palette;
        let gradient = LinearGradient::new(0.0, 0.0, 0.0, self.layout.height);
        add_stop(&gradient, 0.0, &palette.background, 1.0);
        add_stop(&gradient, 1.0, &palette.background_deep, 1.0);
        let _ = cr.set_source(&gradient);
        let _ = cr.paint();
        if palette.backdrop <= 0.0 {
            return;
        }
        let Some(cover) = &self.cover else { return };
        let Some(backdrop) = backdrop(cover, self.layout.width, self.layout.height) else {
            return;
        };
        let _ = cr.save();
        cr.scale(
            self.layout.width / backdrop.width() as f64,
            self.layout.height / backdrop.height() as f64,
        );
        let _ = cr.set_source_surface(&backdrop, 0.0, 0.0);
        cr.source().set_filter(cairo::Filter::Good);
        cr.source().set_extend(cairo::Extend::Pad);
        let _ = cr.paint_with_alpha(palette.backdrop);
        let _ = cr.restore();
        set_color(cr, &palette.background_deep, BACKDROP_SHADE);
        let _ = cr.paint();
    }

    fn header_line(&self, text: &str, weight: Weight, size: f64, width: f64) -> pango::Layout {
        let layout = pango::Layout::new(&self.context);
        layout.set_font_description(Some(&font(self.scene.style.typeface, weight, size)));
        layout.set_width((width * pango::SCALE as f64) as i32);
        layout.set_ellipsize(pango::EllipsizeMode::End);
        layout.set_alignment(match self.layout.header_alignment {
            Alignment::Center => pango::Alignment::Center,
            Alignment::Leading => pango::Alignment::Left,
        });
        layout.set_text(text);
        layout
    }

    fn draw_header(&self, cr: &Context) {
        let rect = self.layout.header;
        let title = self.header_line(&self.scene.title, Weight::Title, self.layout.title_size, rect.width);
        let artist = self.header_line(&self.scene.artist, Weight::Artist, self.layout.artist_size, rect.width);
        let title_height = title.pixel_size().1 as f64;
        let artist_height = artist.pixel_size().1 as f64;
        let gap = 8.0;
        let top = rect.mid_y() - (title_height + gap + artist_height) / 2.0;
        set_color(cr, &self.scene.palette.ink, 1.0);
        cr.move_to(rect.x, top);
        pangocairo::functions::show_layout(cr, &title);
        set_color(cr, &self.scene.palette.ink, 0.72);
        cr.move_to(rect.x, top + title_height + gap);
        pangocairo::functions::show_layout(cr, &artist);
    }

    fn draw_mark(&self, cr: &Context) {
        if !self.scene.style.show_mark {
            return;
        }
        let rect = self.layout.mark;
        let layout = pango::Layout::new(&self.context);
        layout.set_font_description(Some(&font(Typeface::Modern, Weight::Mark, self.layout.mark_size)));
        layout.set_width((rect.width * pango::SCALE as f64) as i32);
        layout.set_alignment(pango::Alignment::Right);
        layout.set_text("Flaccy");
        let height = layout.pixel_size().1 as f64;
        set_color(cr, &self.scene.palette.ink, 0.55);
        cr.move_to(rect.x, rect.mid_y() - height / 2.0);
        pangocairo::functions::show_layout(cr, &layout);
    }

    /// The cover with rounded corners and a soft shadow, or a gradient tile
    /// with a note when the track has no cover.
    fn draw_cover(&self, rect: Rect, radius: f64, cr: &Context) {
        soft_shadow(cr, rect, radius, rect.width * 0.08, rect.width * 0.03, 0.45);
        let _ = cr.save();
        rounded(cr, rect, radius);
        cr.clip();
        match &self.cover {
            Some(cover) => paint_fill(cr, cover, rect, 0.0, 1.0),
            None => self.draw_placeholder(rect, cr),
        }
        let _ = cr.restore();
    }

    fn draw_placeholder(&self, rect: Rect, cr: &Context) {
        let gradient = LinearGradient::new(rect.x, rect.y, rect.max_x(), rect.max_y());
        add_stop(&gradient, 0.0, &self.scene.palette.accent, 1.0);
        add_stop(&gradient, 1.0, &self.scene.palette.background_deep, 1.0);
        let _ = cr.set_source(&gradient);
        let _ = cr.paint();
        let layout = pango::Layout::new(&self.context);
        layout.set_font_description(Some(&font(Typeface::Modern, Weight::Title, rect.width * 0.42)));
        layout.set_text("\u{266A}");
        let (width, height) = layout.pixel_size();
        set_color(cr, &self.scene.palette.ink, 0.8);
        cr.move_to(rect.mid_x() - width as f64 / 2.0, rect.mid_y() - height as f64 / 2.0);
        pangocairo::functions::show_layout(cr, &layout);
    }

    fn draw_disc(&self, frame: usize, cr: &Context) {
        let Some(rect) = self.layout.artwork else { return };
        let level = self.scene.analysis.level_at(frame) as f64;
        let radius = self.layout.artwork_radius * (1.0 + share::DISC_PULSE * level);
        let (x, y) = (rect.mid_x(), rect.mid_y());
        let accent = &self.scene.palette.accent;
        let glow = RadialGradient::new(x, y, radius * 0.9, x, y, radius * 1.35);
        add_stop(&glow, 0.0, accent, 0.35 + 0.4 * level);
        add_stop(&glow, 1.0, accent, 0.0);
        let _ = cr.set_source(&glow);
        cr.arc(x, y, radius * 1.35, 0.0, 2.0 * PI);
        let _ = cr.fill();
        let _ = cr.save();
        cr.arc(x, y, radius, 0.0, 2.0 * PI);
        cr.clip();
        set_color(cr, &self.scene.palette.background_deep, 1.0);
        let _ = cr.paint();
        match (&self.cover, self.scene.style.show_artwork) {
            (Some(cover), true) => {
                let angle = DISC_SPIN * frame as f64 / share::FPS as f64;
                let side = radius * 2.0;
                let disc = Rect { x: x - radius, y: y - radius, width: side, height: side };
                paint_fill(cr, cover, disc, angle, 1.0);
            }
            _ => {
                let orb = RadialGradient::new(x - radius * 0.3, y - radius * 0.3, 0.0, x, y, radius);
                add_stop(&orb, 0.0, accent, 1.0);
                add_stop(&orb, 1.0, &self.scene.palette.background_deep, 1.0);
                let _ = cr.set_source(&orb);
                let _ = cr.paint();
            }
        }
        let _ = cr.restore();
        set_color(cr, &self.scene.palette.ink, 0.14);
        cr.set_line_width(2.0);
        cr.arc(x, y, radius - 1.0, 0.0, 2.0 * PI);
        let _ = cr.stroke();
    }

    fn draw_visualizer(&self, frame: usize, playhead: Option<usize>, cr: &Context) {
        let Some(rect) = self.layout.visualizer else { return };
        let bands = self.scene.analysis.bands_at(frame);
        match self.scene.style.template {
            Template::Pulse => self.draw_ring(&share::ring(&bands), frame, cr),
            Template::Poster => self.draw_wave(rect, playhead, cr),
            Template::Spotlight | Template::Verse => self.draw_strip(&share::strip(&bands), rect, cr),
        }
    }

    fn draw_strip(&self, values: &[f32], rect: Rect, cr: &Context) {
        if values.is_empty() {
            return;
        }
        let slot = rect.width / values.len() as f64;
        let width = slot * (1.0 - share::GAP_RATIO);
        set_color(cr, &self.scene.palette.accent, 0.85);
        for (index, value) in values.iter().enumerate() {
            let height = rect.height * (*value as f64).max(share::MINIMUM_BAR);
            let bar = Rect {
                x: rect.x + slot * index as f64 + (slot - width) / 2.0,
                y: rect.mid_y() - height / 2.0,
                width,
                height,
            };
            rounded(cr, bar, (width / 2.0).min(height / 2.0));
        }
        let _ = cr.fill();
    }

    /// The whole clip's loudness as a slim waveform, lit up to the playhead.
    fn draw_wave(&self, rect: Rect, playhead: Option<usize>, cr: &Context) {
        let levels = &self.scene.analysis.levels;
        if levels.is_empty() {
            return;
        }
        let slot = rect.width / WAVE_COLUMNS as f64;
        let width = slot * (1.0 - share::GAP_RATIO);
        let lit = playhead.map_or(1.0, |frame| frame as f64 / levels.len().max(1) as f64);
        for column in 0..WAVE_COLUMNS {
            let from = column * levels.len() / WAVE_COLUMNS;
            let to = ((column + 1) * levels.len() / WAVE_COLUMNS).max(from + 1).min(levels.len());
            let level = levels[from..to].iter().copied().fold(0.0f32, f32::max);
            let height = rect.height * (level as f64).max(share::MINIMUM_BAR);
            let bar = Rect {
                x: rect.x + slot * column as f64 + (slot - width) / 2.0,
                y: rect.mid_y() - height / 2.0,
                width,
                height,
            };
            if (column as f64 / WAVE_COLUMNS as f64) < lit {
                set_color(cr, &self.scene.palette.accent, 0.9);
            } else {
                set_color(cr, &self.scene.palette.ink, 0.22);
            }
            rounded(cr, bar, (width / 2.0).min(height / 2.0));
            let _ = cr.fill();
        }
    }

    fn draw_ring(&self, values: &[f32], frame: usize, cr: &Context) {
        let Some(rect) = self.layout.artwork else { return };
        if values.is_empty() {
            return;
        }
        let level = self.scene.analysis.level_at(frame) as f64;
        let radius = self.layout.artwork_radius * (1.0 + share::DISC_PULSE * level);
        let inner = radius * share::RING_INNER;
        let width = 2.0 * PI * inner / values.len() as f64 * (1.0 - share::GAP_RATIO);
        let _ = cr.save();
        cr.set_line_cap(cairo::LineCap::Round);
        cr.set_line_width(width);
        set_color(cr, &self.scene.palette.accent, 0.85);
        for (index, value) in values.iter().enumerate() {
            let angle = -PI / 2.0 + 2.0 * PI * index as f64 / values.len() as f64;
            let length = radius * share::RING_LENGTH * (*value as f64).max(share::MINIMUM_BAR);
            cr.move_to(rect.mid_x() + angle.cos() * inner, rect.mid_y() + angle.sin() * inner);
            cr.line_to(
                rect.mid_x() + angle.cos() * (inner + length),
                rect.mid_y() + angle.sin() * (inner + length),
            );
        }
        let _ = cr.stroke();
        let _ = cr.restore();
    }

    fn focus(&self, time: f64) -> Focus {
        share::focus(
            self.scene.selection,
            &self.scene.document,
            time,
            self.scene.window.lyric_start,
        )
    }

    /// One line at a time: the line being sung rises into place as the one
    /// before it rises away.
    fn draw_single(&mut self, time: f64, cr: &Context) {
        if self.single.is_none() {
            let blocks = self
                .texts
                .iter()
                .map(|text| {
                    fitting(
                        &self.context,
                        text,
                        self.scene.style.typeface,
                        self.layout.lyric_size,
                        (self.layout.lyrics.width, self.layout.lyrics.height),
                        self.layout.lyric_alignment,
                    )
                })
                .collect();
            self.single = Some(blocks);
        }
        let focus = self.focus(time);
        let rect = self.layout.lyrics;
        let ranks = [focus.rank.checked_sub(1), Some(focus.rank)];
        for rank in ranks.into_iter().flatten() {
            let opacity = share::ink(rank, &focus, self.scene.style.template);
            if opacity <= 0.002 {
                continue;
            }
            let blocks = self.single.as_ref().expect("built above");
            let block = &blocks[rank];
            let rise = share::RISE * block.font_size;
            let shift = if rank == focus.rank {
                (1.0 - focus.entrance) * rise
            } else {
                -focus.entrance * rise
            };
            let line = &self.scene.document.lines[self.sung[rank]];
            let progress = if rank == focus.rank {
                line.progress(time)
            } else if line.has_words() {
                Some(LineProgress::Done)
            } else {
                None
            };
            let origin = (rect.x, rect.mid_y() - block.height / 2.0 + shift);
            self.draw_lyric(block, line, progress, origin, opacity, 1.0, cr);
        }
    }

    /// The selected lines scrolling past, the one being sung held near the top
    /// third.
    fn draw_verse(&mut self, time: f64, cr: &Context) {
        if self.verse.is_none() {
            let blocks = self
                .texts
                .iter()
                .map(|text| {
                    TextBlock::new(
                        &self.context,
                        text,
                        self.scene.style.typeface,
                        self.layout.lyric_size,
                        self.layout.lyrics.width,
                        self.layout.lyric_alignment,
                    )
                })
                .collect();
            self.verse = Some(blocks);
        }
        let focus = self.focus(time);
        let rect = self.layout.lyrics;
        let blocks = self.verse.as_ref().expect("built above");
        let gap = self.layout.lyric_size * STACK_GAP;
        let mut tops = Vec::with_capacity(blocks.len());
        let mut top = 0.0;
        for block in blocks {
            tops.push(top);
            top += block.height + gap;
        }
        let position = share::scroll_position(&focus);
        let lower = (position.floor() as usize).min(tops.len() - 1);
        let upper = (lower + 1).min(tops.len() - 1);
        let fraction = position - lower as f64;
        let scroll = tops[lower] + (tops[upper] - tops[lower]) * fraction;
        let anchor = rect.y + rect.height * VERSE_ANCHOR;
        let _ = cr.save();
        cr.rectangle(rect.x - 40.0, rect.y, rect.width + 80.0, rect.height);
        cr.clip();
        for (rank, block) in blocks.iter().enumerate() {
            let y = anchor + tops[rank] - scroll;
            if y + block.height <= rect.y || y >= rect.max_y() {
                continue;
            }
            let nearest = (y + block.height - rect.y).min(rect.max_y() - y);
            let fade = (nearest / VERSE_FADE).clamp(0.0, 1.0);
            let line = &self.scene.document.lines[self.sung[rank]];
            let opacity = share::ink(rank, &focus, Template::Verse) * fade;
            let progress = if rank == focus.rank { line.progress(time) } else { None };
            self.draw_lyric(block, line, progress, (rect.x, y), opacity, fade, cr);
        }
        let _ = cr.restore();
    }

    /// Every chosen line at once, fitted to the box: a poster lighting them as
    /// they are sung, or the still card with all of them lit.
    fn draw_stack(&mut self, time: Option<f64>, cr: &Context) {
        if self.stack.is_none() {
            self.stack = Some(self.fitted_stack());
        }
        let blocks = self.stack.as_ref().expect("built above");
        let Some(first) = blocks.first() else { return };
        let rect = self.layout.lyrics;
        let gap = first.font_size * STACK_GAP;
        let total: f64 = blocks.iter().map(|block| block.height).sum::<f64>()
            + gap * (blocks.len() - 1) as f64;
        let mut y = rect.mid_y() - total / 2.0;
        let focus = time.map(|time| self.focus(time));
        for (rank, block) in blocks.iter().enumerate() {
            match (focus, time, self.scene.is_timed()) {
                (Some(focus), Some(time), true) => {
                    let line = &self.scene.document.lines[self.sung[rank]];
                    let opacity = share::ink(rank, &focus, Template::Poster);
                    let progress = if rank == focus.rank { line.progress(time) } else { None };
                    self.draw_lyric(block, line, progress, (rect.x, y), opacity, 1.0, cr);
                }
                _ => {
                    set_color(cr, &self.scene.palette.ink, 1.0);
                    block.draw(cr, rect.x, y);
                }
            }
            y += block.height + gap;
        }
    }

    /// The chosen lines laid out at one size small enough for all of them.
    fn fitted_stack(&self) -> Vec<TextBlock> {
        let rect = self.layout.lyrics;
        let mut size = self.layout.lyric_size;
        let smallest = size * share::MINIMUM_LYRIC_SCALE;
        loop {
            let blocks: Vec<TextBlock> = self
                .texts
                .iter()
                .map(|text| {
                    TextBlock::new(
                        &self.context,
                        text,
                        self.scene.style.typeface,
                        size,
                        rect.width,
                        self.layout.lyric_alignment,
                    )
                })
                .collect();
            let gap = size * STACK_GAP;
            let total: f64 = blocks.iter().map(|block| block.height).sum::<f64>()
                + gap * blocks.len().saturating_sub(1) as f64;
            if total <= rect.height || size <= smallest {
                return blocks;
            }
            size = (size * 0.92).max(smallest);
        }
    }

    /// A lyric line at `opacity`. A line with timed words that is being sung
    /// fills from dim to bright through the word under the clock, with a soft
    /// edge; a line without timed words is drawn at `opacity` alone.
    #[allow(clippy::too_many_arguments)]
    fn draw_lyric(
        &self,
        block: &TextBlock,
        line: &Line,
        progress: Option<LineProgress>,
        origin: (f64, f64),
        opacity: f64,
        fade: f64,
        cr: &Context,
    ) {
        let ink = &self.scene.palette.ink;
        let progress = match progress {
            Some(progress) if line.has_words() => progress,
            _ => {
                set_color(cr, ink, opacity);
                block.draw(cr, origin.0, origin.1);
                return;
            }
        };
        let dim = share::DIM * fade;
        match progress {
            LineProgress::NotStarted => {
                set_color(cr, ink, opacity.min(dim));
                block.draw(cr, origin.0, origin.1);
            }
            LineProgress::Done => {
                set_color(cr, ink, opacity);
                block.draw(cr, origin.0, origin.1);
            }
            LineProgress::Singing { word, fraction } => {
                let single = matches!(self.scene.style.template, Template::Spotlight | Template::Pulse);
                let bright = if single { opacity } else { fade };
                set_color(cr, ink, opacity.min(dim));
                block.draw(cr, origin.0, origin.1);
                let edge = fill_edge(block, line, word, fraction);
                self.paint_fill(block, edge, origin, bright, cr);
            }
        }
    }

    fn paint_fill(&self, block: &TextBlock, edge: (usize, f64), origin: (f64, f64), alpha: f64, cr: &Context) {
        for row in 0..=edge.0.min(block.rows.len().saturating_sub(1)) {
            let (row_x, row_y, row_width, row_height) = block.rows[row];
            let top = origin.1 + row_y;
            let left = origin.0 + row_x - 4.0;
            let right = origin.0 + row_x + row_width + 4.0;
            if row < edge.0 {
                self.paint(block, (left, top, right - left, row_height), alpha, origin, cr);
                continue;
            }
            let x = origin.0 + edge.1;
            let solid = if block.rtl {
                (x + FILL_SOFTNESS, top, (right - x - FILL_SOFTNESS).max(0.0), row_height)
            } else {
                (left, top, (x - FILL_SOFTNESS - left).max(0.0), row_height)
            };
            self.paint(block, solid, alpha, origin, cr);
            let width = FILL_SOFTNESS / FILL_SLICES as f64;
            for slice in 0..FILL_SLICES {
                let slice_x = if block.rtl {
                    x + FILL_SOFTNESS - width * (slice + 1) as f64
                } else {
                    x - FILL_SOFTNESS + width * slice as f64
                };
                let strength = 1.0 - (slice as f64 + 0.5) / FILL_SLICES as f64;
                self.paint(block, (slice_x, top, width, row_height), alpha * strength, origin, cr);
            }
        }
    }

    fn paint(&self, block: &TextBlock, clip: (f64, f64, f64, f64), alpha: f64, origin: (f64, f64), cr: &Context) {
        if clip.2 <= 0.0 || clip.3 <= 0.0 {
            return;
        }
        let _ = cr.save();
        cr.rectangle(clip.0, clip.1, clip.2, clip.3);
        cr.clip();
        set_color(cr, &self.scene.palette.ink, alpha);
        block.draw(cr, origin.0, origin.1);
        let _ = cr.restore();
    }
}

/// Where the fill stands inside the word being sung: the row and the x
/// between the word's first letter and its last.
fn fill_edge(block: &TextBlock, line: &Line, word: usize, fraction: f64) -> (usize, f64) {
    let offset: usize = line.words[..word].iter().map(|word| word.text.len()).sum();
    let trimmed = line.words[word].text.trim_end().len().max(1);
    let start = block.position(offset);
    let end = block.position(offset + trimmed);
    if end.0 != start.0 {
        let (row_x, _, row_width, _) = block.rows[start.0];
        return (start.0, start.1 + fraction * (row_x + row_width - start.1));
    }
    (start.0, start.1 + (end.1 - start.1) * fraction)
}

fn surface_from(cover: &Cover) -> Option<ImageSurface> {
    ImageSurface::create_for_data(
        cover.data.clone(),
        Format::ARgb32,
        cover.width,
        cover.height,
        cover.stride,
    )
    .ok()
}

/// The cover filled into the canvas's shape at a small size and blurred
/// there, so stretching it over the canvas is all the softness it needs.
fn backdrop(cover: &ImageSurface, width: f64, height: f64) -> Option<ImageSurface> {
    let small_width = BACKDROP_WIDTH;
    let small_height = ((small_width as f64 * height / width).round() as i32).max(1);
    let mut small = ImageSurface::create(Format::ARgb32, small_width, small_height).ok()?;
    {
        let cr = Context::new(&small).ok()?;
        let rect = Rect { x: 0.0, y: 0.0, width: small_width as f64, height: small_height as f64 };
        paint_fill(&cr, cover, rect, 0.0, 1.0);
    }
    small.flush();
    let stride = small.stride() as usize;
    let mut pixels = image::RgbaImage::new(small_width as u32, small_height as u32);
    {
        let data = small.data().ok()?;
        for y in 0..small_height as usize {
            for x in 0..small_width as usize {
                let at = y * stride + x * 4;
                pixels.put_pixel(x as u32, y as u32, image::Rgba([data[at], data[at + 1], data[at + 2], 255]));
            }
        }
    }
    let blurred = image::imageops::blur(&pixels, BACKDROP_SIGMA);
    {
        let mut data = small.data().ok()?;
        for y in 0..small_height as usize {
            for x in 0..small_width as usize {
                let at = y * stride + x * 4;
                let pixel = blurred.get_pixel(x as u32, y as u32);
                data[at] = pixel[0];
                data[at + 1] = pixel[1];
                data[at + 2] = pixel[2];
                data[at + 3] = 255;
            }
        }
    }
    small.mark_dirty();
    Some(small)
}

/// Paints `image` to fill `rect` the way aspect-fill does, turned by `angle`
/// about the rect's centre.
fn paint_fill(cr: &Context, image: &ImageSurface, rect: Rect, angle: f64, alpha: f64) {
    let (width, height) = (image.width() as f64, image.height() as f64);
    if width <= 0.0 || height <= 0.0 {
        return;
    }
    let factor = (rect.width / width).max(rect.height / height);
    let _ = cr.save();
    cr.translate(rect.mid_x(), rect.mid_y());
    cr.rotate(angle);
    cr.scale(factor, factor);
    let _ = cr.set_source_surface(image, -width / 2.0, -height / 2.0);
    cr.source().set_filter(cairo::Filter::Best);
    let _ = cr.paint_with_alpha(alpha);
    let _ = cr.restore();
}

/// A shadow under a rounded rectangle, built from a few widening layers since
/// Cairo has no blur of its own.
fn soft_shadow(cr: &Context, rect: Rect, radius: f64, blur: f64, drop: f64, alpha: f64) {
    let layers = 8;
    for layer in 0..layers {
        let spread = blur * (layer as f64 + 1.0) / layers as f64;
        let grown = Rect {
            x: rect.x - spread / 2.0,
            y: rect.y + drop - spread / 2.0,
            width: rect.width + spread,
            height: rect.height + spread,
        };
        cr.set_source_rgba(0.0, 0.0, 0.0, alpha / layers as f64 * 0.9);
        rounded(cr, grown, radius + spread / 2.0);
        let _ = cr.fill();
    }
}

fn rounded(cr: &Context, rect: Rect, radius: f64) {
    let radius = radius.min(rect.width / 2.0).min(rect.height / 2.0).max(0.0);
    cr.new_sub_path();
    cr.arc(rect.max_x() - radius, rect.y + radius, radius, -PI / 2.0, 0.0);
    cr.arc(rect.max_x() - radius, rect.max_y() - radius, radius, 0.0, PI / 2.0);
    cr.arc(rect.x + radius, rect.max_y() - radius, radius, PI / 2.0, PI);
    cr.arc(rect.x + radius, rect.y + radius, radius, PI, 1.5 * PI);
    cr.close_path();
}

fn set_color(cr: &Context, color: &Color, alpha: f64) {
    cr.set_source_rgba(color.red, color.green, color.blue, alpha.clamp(0.0, 1.0));
}

fn add_stop(gradient: &cairo::Gradient, offset: f64, color: &Color, alpha: f64) {
    gradient.add_color_stop_rgba(offset, color.red, color.green, color.blue, alpha);
}
