/// The aspect a picture is assumed to have before its first frame says
/// otherwise.
pub const DEFAULT_ASPECT: f64 = 16.0 / 9.0;

/// The lyrics column's share of the stage width, and the narrowest and widest
/// it gets, in logical pixels at 100 % zoom.
const COLUMN_SHARE: f64 = 0.34;
const COLUMN_MIN: f64 = 320.0;
const COLUMN_MAX: f64 = 560.0;
/// The same for Up Next.
const QUEUE_SHARE: f64 = 0.28;
const QUEUE_MIN: f64 = 300.0;
const QUEUE_MAX: f64 = 420.0;
/// Neither column may take more than this share of the stage.
const COLUMN_CEILING: f64 = 0.6;
/// The least height lyrics under the picture are given, and the widest that
/// column is set.
const BELOW_MIN: f64 = 240.0;
const BELOW_MAX_WIDTH: f64 = 760.0;
/// Room around a picture that shares the stage with a column, and between the
/// two.
const MARGIN: f64 = 24.0;
const GUTTER: f64 = 28.0;
/// A column only moves beside or under the picture when the picture keeps at
/// least this share of the area it has on its own; otherwise it lies over it.
const KEEP_SHARE: f64 = 0.85;
/// A picture alone fills the stage edge to edge when that crops at most this
/// share of it.
const FILL_CROP: f64 = 0.08;
/// Automatic lyrics turn into captions once a column would cover more than
/// this share of the picture's width.
const CAPTIONS_WHEN_COVERING: f64 = 0.42;
/// How far the shade under a column reaches past the column itself.
const SCRIM_REACH: f64 = 1.45;
/// The captions band: its share of the picture height, its least height, how
/// far above the picture's foot the text sits, and the picture height their
/// scale is measured against.
const CAPTION_BAND: f64 = 0.45;
const CAPTION_BAND_MIN: f64 = 160.0;
const CAPTION_LIFT: f64 = 0.06;
const CAPTION_REFERENCE_HEIGHT: f64 = 620.0;
const CAPTION_BASE_SCALE: f64 = 1.4;
/// The title card's inset from the picture's corner and its lift off the
/// dock or the picture's foot.
const CARD_INSET: f64 = 24.0;
const CARD_LIFT: f64 = 20.0;
/// The narrowest picture that still gets a title card.
const CARD_MIN_WIDTH: f64 = 280.0;
/// The gap between a floating Up Next sheet and the stage edge and chrome.
const SHEET_GAP: f64 = 12.0;

/// A rectangle in the stage's coordinates, in logical pixels.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl Rect {
    pub const fn new(x: f64, y: f64, width: f64, height: f64) -> Self {
        Self {
            x,
            y,
            width,
            height,
        }
    }

    pub fn right(self) -> f64 {
        self.x + self.width
    }

    pub fn bottom(self) -> f64 {
        self.y + self.height
    }

    pub fn area(self) -> f64 {
        self.width.max(0.0) * self.height.max(0.0)
    }

    pub fn intersection(self, other: Rect) -> Rect {
        let x = self.x.max(other.x);
        let y = self.y.max(other.y);
        let right = self.right().min(other.right());
        let bottom = self.bottom().min(other.bottom());
        Rect::new(x, y, (right - x).max(0.0), (bottom - y).max(0.0))
    }

    pub fn lerp(self, to: Rect, t: f64) -> Rect {
        let mix = |a: f64, b: f64| a + (b - a) * t;
        Rect::new(
            mix(self.x, to.x),
            mix(self.y, to.y),
            mix(self.width, to.width),
            mix(self.height, to.height),
        )
    }

    /// The largest rectangle of `aspect` that fits inside this one, centred.
    pub fn fit(self, aspect: f64) -> Rect {
        let (width, height) = if self.width / self.height > aspect {
            (self.height * aspect, self.height)
        } else {
            (self.width, self.width / aspect)
        };
        Rect::new(
            self.x + (self.width - width) / 2.0,
            self.y + (self.height - height) / 2.0,
            width,
            height,
        )
    }

    /// The smallest rectangle of `aspect` that covers this one, centred.
    pub fn cover(self, aspect: f64) -> Rect {
        let (width, height) = if self.width / self.height > aspect {
            (self.width, self.width / aspect)
        } else {
            (self.height * aspect, self.height)
        };
        Rect::new(
            self.x + (self.width - width) / 2.0,
            self.y + (self.height - height) / 2.0,
            width,
            height,
        )
    }
}

/// Which side of the stage the lyrics column keeps to; Up Next takes the
/// other.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Side {
    Left,
    Right,
}

/// How lyrics are shown over a music video, as chosen in its options.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LyricsStyle {
    /// A column beside, under or over the picture, and captions once a column
    /// would hide too much of it.
    Auto,
    Column,
    Captions,
}

impl LyricsStyle {
    pub const ALL: [LyricsStyle; 3] = [
        LyricsStyle::Auto,
        LyricsStyle::Column,
        LyricsStyle::Captions,
    ];

    pub fn id(self) -> &'static str {
        match self {
            LyricsStyle::Auto => "auto",
            LyricsStyle::Column => "column",
            LyricsStyle::Captions => "captions",
        }
    }

    pub fn from_id(id: &str) -> Self {
        Self::ALL
            .into_iter()
            .find(|style| style.id() == id)
            .unwrap_or(LyricsStyle::Auto)
    }

    pub fn label(self) -> &'static str {
        match self {
            LyricsStyle::Auto => "Auto",
            LyricsStyle::Column => "Column",
            LyricsStyle::Captions => "Captions",
        }
    }
}

/// Where the lyrics ended up.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Placement {
    Beside,
    Below,
    Over,
    Captions,
}

/// Everything the arrangement depends on.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct StageInput {
    pub width: f64,
    pub height: f64,
    /// The picture's aspect once any bars burnt into it are cropped away.
    pub aspect: f64,
    /// `None` while the lyrics are switched off.
    pub lyrics: Option<LyricsStyle>,
    pub queue: bool,
    pub lyrics_side: Side,
    /// The interface zoom, which every minimum and margin scales with.
    pub zoom: f64,
    /// How far the header and the transport dock reach into the stage.
    pub top_inset: f64,
    pub bottom_inset: f64,
}

impl Default for StageInput {
    fn default() -> Self {
        Self {
            width: 0.0,
            height: 0.0,
            aspect: DEFAULT_ASPECT,
            lyrics: None,
            queue: false,
            lyrics_side: Side::Left,
            zoom: 1.0,
            top_inset: 0.0,
            bottom_inset: 0.0,
        }
    }
}

/// The captions band across the foot of the picture: where it lies, how far
/// above its foot the text sits, and how much larger than the lyrics font the
/// text is set.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Captions {
    pub band: Rect,
    pub margin: f64,
    pub scale: f64,
}

/// Where the title card is pinned: a corner point, which way the card grows
/// from it, and whether it hangs down from it or stands up on it.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Anchor {
    pub x: f64,
    pub y: f64,
    pub align_right: bool,
    pub from_top: bool,
}

/// The shade laid under a column that lies over the picture, darkest on
/// `side`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Scrim {
    pub rect: Rect,
    pub side: Side,
}

/// Where everything on the stage goes.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Arrangement {
    /// Where the picture is drawn. A picture filling the stage overhangs it
    /// and is clipped.
    pub video: Rect,
    /// Whether the picture stands clear of every stage edge, so it is drawn
    /// as a framed screen with rounded corners.
    pub floating: bool,
    pub lyrics: Option<(Placement, Rect)>,
    pub captions: Option<Captions>,
    pub scrim: Option<Scrim>,
    /// Up Next and whether it floats over the stage as a sheet rather than
    /// standing beside the picture.
    pub queue: Option<(Rect, bool)>,
    pub card: Option<Anchor>,
}

impl Arrangement {
    pub fn placement(&self) -> Option<Placement> {
        self.lyrics.map(|(placement, _)| placement)
    }

    /// The part of the picture inside the stage.
    pub fn visible_video(&self, width: f64, height: f64) -> Rect {
        self.video.intersection(Rect::new(0.0, 0.0, width, height))
    }
}

/// Lays the stage out so the picture is as large as the window allows: a
/// column moves beside or under it when that costs the picture little, lies
/// over it under a shade when it does not, and gives way to captions when
/// even that would hide too much of the picture.
pub fn arrange(input: StageInput) -> Arrangement {
    if input.width < 1.0 || input.height < 1.0 {
        return Arrangement::default();
    }
    let input = StageInput {
        aspect: if input.aspect.is_finite() && input.aspect > 0.05 {
            input.aspect
        } else {
            DEFAULT_ASPECT
        },
        zoom: input.zoom.max(0.25),
        ..input
    };
    let stage = Rect::new(0.0, 0.0, input.width, input.height);
    let alone = stage.fit(input.aspect).area();
    let column = (input.width * COLUMN_SHARE)
        .clamp(COLUMN_MIN * input.zoom, COLUMN_MAX * input.zoom)
        .min(input.width * COLUMN_CEILING);
    let queue = input.queue.then(|| {
        (input.width * QUEUE_SHARE)
            .clamp(QUEUE_MIN * input.zoom, QUEUE_MAX * input.zoom)
            .min(input.width * COLUMN_CEILING)
    });

    if matches!(input.lyrics, Some(LyricsStyle::Auto | LyricsStyle::Column)) {
        if let Some(queue) = queue {
            if let Some(both) = beside(&input, alone, column, queue) {
                return both;
            }
        }
        if let Some(arrangement) = beside(&input, alone, column, 0.0) {
            return arrangement;
        }
        if let Some(arrangement) = below(&input, alone) {
            return arrangement;
        }
        let over = over(&input, column, queue);
        let covering = over.scrim.map_or(0.0, |_| {
            let visible = over.visible_video(input.width, input.height);
            let column_rect = over.lyrics.map(|(_, rect)| rect).unwrap_or_default();
            visible.intersection(column_rect).width / visible.width.max(1.0)
        });
        if input.lyrics == Some(LyricsStyle::Column) || covering <= CAPTIONS_WHEN_COVERING {
            return over;
        }
    }

    let captions = input.lyrics.is_some();
    if let Some(queue) = queue {
        if let Some(arrangement) = beside_queue(&input, alone, queue, captions) {
            return arrangement;
        }
    }
    let video = alone_picture(stage, input.aspect);
    finish(
        &input,
        video,
        None,
        None,
        queue.map(|width| sheet(&input, width)),
        captions,
    )
}

/// The picture with nothing beside it: edge to edge when that crops little,
/// otherwise fitted.
fn alone_picture(stage: Rect, aspect: f64) -> Rect {
    let fitted = stage.fit(aspect);
    if 1.0 - fitted.area() / stage.area() <= FILL_CROP {
        stage.cover(aspect)
    } else {
        fitted
    }
}

/// Lyrics and, when `queue` is wider than nothing, Up Next as columns either
/// side of a framed picture, if the picture keeps enough of its size.
fn beside(input: &StageInput, alone: f64, lyrics: f64, queue: f64) -> Option<Arrangement> {
    let zoom = input.zoom;
    let gutter = GUTTER * zoom;
    let margin = MARGIN * zoom;
    let used = lyrics + gutter + if queue > 0.0 { queue + gutter } else { 0.0 };
    let room = Rect::new(
        margin,
        margin,
        input.width - 2.0 * margin - used,
        input.height - 2.0 * margin,
    );
    if room.width <= 0.0 || room.height <= 0.0 {
        return None;
    }
    let picture = room.fit(input.aspect);
    if picture.area() < KEEP_SHARE * alone {
        return None;
    }
    let group = used + picture.width;
    let start = ((input.width - group) / 2.0).max(margin);
    let (left_width, right_width) = match input.lyrics_side {
        Side::Left => (lyrics, queue),
        Side::Right => (queue, lyrics),
    };
    let left = (left_width > 0.0).then(|| Rect::new(start, 0.0, left_width, input.height));
    let picture_x = start + left.map_or(0.0, |rect| rect.width + gutter);
    let video = Rect::new(
        picture_x,
        (input.height - picture.height) / 2.0,
        picture.width,
        picture.height,
    );
    let right = (right_width > 0.0)
        .then(|| Rect::new(video.right() + gutter, 0.0, right_width, input.height));
    let (lyrics_rect, queue_rect) = match input.lyrics_side {
        Side::Left => (left, right),
        Side::Right => (right, left),
    };
    let queue = match queue_rect {
        Some(rect) => Some((column_between_chrome(input, rect), false)),
        None => input.queue.then(|| {
            let width = (input.width * QUEUE_SHARE)
                .clamp(QUEUE_MIN * zoom, QUEUE_MAX * zoom)
                .min(input.width * COLUMN_CEILING);
            sheet(input, width)
        }),
    };
    Some(finish(
        input,
        video,
        lyrics_rect.map(|rect| (Placement::Beside, rect)),
        None,
        queue,
        false,
    ))
}

/// Up Next beside a picture that has the lyrics over it as captions, or no
/// lyrics at all.
fn beside_queue(input: &StageInput, alone: f64, queue: f64, captions: bool) -> Option<Arrangement> {
    let zoom = input.zoom;
    let gutter = GUTTER * zoom;
    let margin = MARGIN * zoom;
    let room = Rect::new(
        margin,
        margin,
        input.width - 2.0 * margin - queue - gutter,
        input.height - 2.0 * margin,
    );
    if room.width <= 0.0 || room.height <= 0.0 {
        return None;
    }
    let picture = room.fit(input.aspect);
    if picture.area() < KEEP_SHARE * alone {
        return None;
    }
    let group = queue + gutter + picture.width;
    let start = ((input.width - group) / 2.0).max(margin);
    let (video_x, queue_x) = match input.lyrics_side {
        Side::Left => (start, start + picture.width + gutter),
        Side::Right => (start + queue + gutter, start),
    };
    let video = Rect::new(
        video_x,
        (input.height - picture.height) / 2.0,
        picture.width,
        picture.height,
    );
    let queue = column_between_chrome(input, Rect::new(queue_x, 0.0, queue, input.height));
    Some(finish(
        input,
        video,
        None,
        None,
        Some((queue, false)),
        captions,
    ))
}

/// The picture across the top with the lyrics under it, for a window taller
/// than the picture needs.
fn below(input: &StageInput, alone: f64) -> Option<Arrangement> {
    let zoom = input.zoom;
    let margin = MARGIN * zoom;
    let top = margin.max(input.top_inset + margin / 2.0);
    let room = Rect::new(
        margin,
        top,
        input.width - 2.0 * margin,
        input.height - top - GUTTER * zoom - BELOW_MIN * zoom,
    );
    if room.width <= 0.0 || room.height <= 0.0 {
        return None;
    }
    let picture = room.fit(input.aspect);
    if picture.area() < KEEP_SHARE * alone {
        return None;
    }
    let video = Rect::new(
        (input.width - picture.width) / 2.0,
        top,
        picture.width,
        picture.height,
    );
    let lyrics_top = video.bottom() + GUTTER * zoom / 2.0;
    let lyrics_width = (input.width - 2.0 * margin).min(BELOW_MAX_WIDTH * zoom);
    let lyrics = Rect::new(
        (input.width - lyrics_width) / 2.0,
        lyrics_top,
        lyrics_width,
        input.height - lyrics_top,
    );
    let queue = input.queue.then(|| {
        let width = (input.width * QUEUE_SHARE)
            .clamp(QUEUE_MIN * zoom, QUEUE_MAX * zoom)
            .min(input.width * COLUMN_CEILING);
        sheet(input, width)
    });
    Some(finish(
        input,
        video,
        Some((Placement::Below, lyrics)),
        None,
        queue,
        false,
    ))
}

/// The picture as large as the stage allows, shifted away from the column
/// as far as it can go, with the column over it under a shade.
fn over(input: &StageInput, column: f64, queue: Option<f64>) -> Arrangement {
    let stage = Rect::new(0.0, 0.0, input.width, input.height);
    let mut video = alone_picture(stage, input.aspect);
    let free = match input.lyrics_side {
        Side::Left => Rect::new(column, 0.0, input.width - column, input.height),
        Side::Right => Rect::new(0.0, 0.0, input.width - column, input.height),
    };
    if video.width < input.width {
        let centred = free.x + (free.width - video.width) / 2.0;
        video.x = centred.clamp(0.0, input.width - video.width);
    }
    let lyrics = match input.lyrics_side {
        Side::Left => Rect::new(0.0, 0.0, column, input.height),
        Side::Right => Rect::new(input.width - column, 0.0, column, input.height),
    };
    let reach = (column * SCRIM_REACH).min(input.width);
    let scrim = Scrim {
        rect: match input.lyrics_side {
            Side::Left => Rect::new(0.0, 0.0, reach, input.height),
            Side::Right => Rect::new(input.width - reach, 0.0, reach, input.height),
        },
        side: input.lyrics_side,
    };
    finish(
        input,
        video,
        Some((Placement::Over, lyrics)),
        Some(scrim),
        queue.map(|width| sheet(input, width)),
        false,
    )
}

/// Up Next floating over the stage on the side away from the lyrics, clear of
/// the header and the dock.
fn sheet(input: &StageInput, width: f64) -> (Rect, bool) {
    let gap = SHEET_GAP * input.zoom;
    let x = match input.lyrics_side {
        Side::Left => input.width - width - gap,
        Side::Right => gap,
    };
    (
        column_between_chrome(input, Rect::new(x, 0.0, width, input.height)),
        true,
    )
}

/// A column cut down to the stretch between the header and the dock, so a
/// list's first and last rows are never under either.
fn column_between_chrome(input: &StageInput, rect: Rect) -> Rect {
    let gap = SHEET_GAP * input.zoom;
    let top = input.top_inset + gap;
    let height = (input.height - top - input.bottom_inset - gap).max(120.0 * input.zoom);
    Rect::new(rect.x, top, rect.width, height)
}

/// Fills in what follows from where the picture and the columns went: the
/// floating frame, the captions band and the title card.
fn finish(
    input: &StageInput,
    video: Rect,
    lyrics: Option<(Placement, Rect)>,
    scrim: Option<Scrim>,
    queue: Option<(Rect, bool)>,
    captions: bool,
) -> Arrangement {
    let edge = 0.5;
    let floating = video.x > edge
        && video.y > edge
        && video.right() < input.width - edge
        && video.bottom() < input.height - edge;
    let visible = video.intersection(Rect::new(0.0, 0.0, input.width, input.height));
    let captions = captions.then(|| captions_band(input, visible));
    let lyrics = match captions {
        Some(band) => Some((Placement::Captions, band.band)),
        None => lyrics,
    };
    let card = title_card(
        input,
        visible,
        lyrics.map(|(placement, _)| placement),
        queue,
    );
    Arrangement {
        video,
        floating,
        lyrics,
        captions,
        scrim,
        queue,
        card,
    }
}

fn captions_band(input: &StageInput, visible: Rect) -> Captions {
    let height = (visible.height * CAPTION_BAND)
        .max(CAPTION_BAND_MIN * input.zoom)
        .min(visible.height);
    let band = Rect::new(visible.x, visible.bottom() - height, visible.width, height);
    let text_bottom = (input.height - input.bottom_inset - SHEET_GAP * input.zoom)
        .min(visible.bottom() - visible.height * CAPTION_LIFT);
    Captions {
        band,
        margin: (band.bottom() - text_bottom).max(0.0),
        scale: CAPTION_BASE_SCALE
            * (visible.height / (CAPTION_REFERENCE_HEIGHT * input.zoom)).clamp(0.85, 1.9),
    }
}

/// The title card sits in a lower corner of the picture, on the side the
/// lyrics leave free; with captions along the foot it moves to the top.
fn title_card(
    input: &StageInput,
    visible: Rect,
    placement: Option<Placement>,
    queue: Option<(Rect, bool)>,
) -> Option<Anchor> {
    let zoom = input.zoom;
    if visible.width < CARD_MIN_WIDTH * zoom {
        return None;
    }
    let inset = CARD_INSET * zoom;
    let anchor = if placement == Some(Placement::Captions) {
        Anchor {
            x: visible.x + inset,
            y: visible.y.max(input.top_inset) + inset * 0.66,
            align_right: false,
            from_top: true,
        }
    } else {
        let y = visible.bottom().min(input.height - input.bottom_inset) - CARD_LIFT * zoom;
        let right = placement == Some(Placement::Over) && input.lyrics_side == Side::Left;
        Anchor {
            x: if right {
                visible.right() - inset
            } else {
                visible.x + inset
            },
            y,
            align_right: right,
            from_top: false,
        }
    };
    let under_sheet = queue.is_some_and(|(rect, floating)| {
        floating && (anchor.x >= rect.x - inset && anchor.x <= rect.right() + inset)
    });
    (!under_sheet).then_some(anchor)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn input(width: f64, height: f64) -> StageInput {
        StageInput {
            width,
            height,
            top_inset: 46.0,
            bottom_inset: 130.0,
            ..StageInput::default()
        }
    }

    fn with_lyrics(width: f64, height: f64, style: LyricsStyle) -> StageInput {
        StageInput {
            lyrics: Some(style),
            ..input(width, height)
        }
    }

    fn overlaps(a: Rect, b: Rect) -> bool {
        a.intersection(b).area() > 0.0
    }

    #[test]
    fn a_maximized_sixteen_by_nine_window_lays_the_lyrics_over_the_picture() {
        let arrangement = arrange(with_lyrics(2560.0, 1440.0, LyricsStyle::Auto));
        assert_eq!(arrangement.placement(), Some(Placement::Over));
        assert_eq!(arrangement.video, Rect::new(0.0, 0.0, 2560.0, 1440.0));
        let (_, column) = arrangement.lyrics.unwrap();
        assert_eq!(column, Rect::new(0.0, 0.0, 560.0, 1440.0));
        let scrim = arrangement.scrim.unwrap();
        assert_eq!(scrim.side, Side::Left);
        assert!(scrim.rect.width > column.width);
        assert!(!arrangement.floating);
    }

    #[test]
    fn an_ultrawide_window_sets_the_lyrics_beside_a_framed_picture() {
        let arrangement = arrange(with_lyrics(3440.0, 1440.0, LyricsStyle::Auto));
        assert_eq!(arrangement.placement(), Some(Placement::Beside));
        let (_, column) = arrangement.lyrics.unwrap();
        assert!(!overlaps(column, arrangement.video));
        assert!(column.right() <= arrangement.video.x);
        assert!(arrangement.floating);
        assert!(arrangement.scrim.is_none());
        let alone = Rect::new(0.0, 0.0, 3440.0, 1440.0)
            .fit(DEFAULT_ASPECT)
            .area();
        assert!(arrangement.video.area() >= KEEP_SHARE * alone);
    }

    #[test]
    fn a_tall_window_puts_the_lyrics_under_the_picture() {
        let arrangement = arrange(with_lyrics(1280.0, 1440.0, LyricsStyle::Auto));
        assert_eq!(arrangement.placement(), Some(Placement::Below));
        let (_, lyrics) = arrangement.lyrics.unwrap();
        assert!(lyrics.y >= arrangement.video.bottom());
        assert!(lyrics.height >= BELOW_MIN);
        assert!(arrangement.video.y >= 46.0);
    }

    #[test]
    fn a_small_window_turns_automatic_lyrics_into_captions() {
        let arrangement = arrange(with_lyrics(700.0, 500.0, LyricsStyle::Auto));
        assert_eq!(arrangement.placement(), Some(Placement::Captions));
        let captions = arrangement.captions.unwrap();
        let visible = arrangement.visible_video(700.0, 500.0);
        assert!(captions.band.bottom() <= visible.bottom() + 1e-9);
        assert_eq!(captions.band.width, visible.width);
        assert!(arrangement.scrim.is_none());
    }

    #[test]
    fn a_column_by_choice_stays_a_column_however_small_the_window() {
        let arrangement = arrange(with_lyrics(700.0, 500.0, LyricsStyle::Column));
        assert_eq!(arrangement.placement(), Some(Placement::Over));
    }

    #[test]
    fn captions_by_choice_ride_over_the_picture_even_on_an_ultrawide() {
        let arrangement = arrange(with_lyrics(3440.0, 1440.0, LyricsStyle::Captions));
        assert_eq!(arrangement.placement(), Some(Placement::Captions));
    }

    #[test]
    fn caption_text_stays_above_the_dock() {
        let stage = with_lyrics(1920.0, 1080.0, LyricsStyle::Captions);
        let arrangement = arrange(stage);
        let captions = arrangement.captions.unwrap();
        let text_bottom = captions.band.bottom() - captions.margin;
        assert!(text_bottom <= 1080.0 - stage.bottom_inset);
    }

    #[test]
    fn captions_grow_with_the_picture() {
        let small = arrange(with_lyrics(800.0, 450.0, LyricsStyle::Captions));
        let large = arrange(with_lyrics(2560.0, 1440.0, LyricsStyle::Captions));
        assert!(large.captions.unwrap().scale > small.captions.unwrap().scale);
    }

    #[test]
    fn a_picture_alone_fills_a_window_of_nearly_its_shape() {
        let arrangement = arrange(input(1920.0, 1050.0));
        let visible = arrangement.visible_video(1920.0, 1050.0);
        assert_eq!(visible, Rect::new(0.0, 0.0, 1920.0, 1050.0));
        assert!(arrangement.video.width >= 1920.0);
        assert!(arrangement.lyrics.is_none());
    }

    #[test]
    fn a_picture_alone_is_fitted_when_filling_would_crop_too_much() {
        let arrangement = arrange(input(1600.0, 1000.0));
        assert_eq!(arrangement.video, Rect::new(0.0, 50.0, 1600.0, 900.0));
        assert!(!arrangement.floating);
    }

    #[test]
    fn a_four_by_three_picture_moves_away_from_the_column_over_it() {
        let stage = StageInput {
            aspect: 4.0 / 3.0,
            ..with_lyrics(1600.0, 1000.0, LyricsStyle::Auto)
        };
        let arrangement = arrange(stage);
        assert_eq!(arrangement.placement(), Some(Placement::Over));
        assert!((arrangement.video.right() - 1600.0).abs() < 1e-9);
        let (_, column) = arrangement.lyrics.unwrap();
        let covered = column.intersection(arrangement.video).width / arrangement.video.width;
        assert!(covered < 0.25, "covered {covered}");
    }

    #[test]
    fn swapping_sides_mirrors_the_column_and_the_card() {
        let stage = StageInput {
            lyrics_side: Side::Right,
            ..with_lyrics(2560.0, 1440.0, LyricsStyle::Auto)
        };
        let arrangement = arrange(stage);
        let (_, column) = arrangement.lyrics.unwrap();
        assert_eq!(column.right(), 2560.0);
        assert_eq!(arrangement.scrim.unwrap().side, Side::Right);
        assert!(!arrangement.card.unwrap().align_right);
        let left = arrange(with_lyrics(2560.0, 1440.0, LyricsStyle::Auto));
        assert!(left.card.unwrap().align_right);
    }

    #[test]
    fn a_super_ultrawide_window_stands_both_columns_beside_the_picture() {
        let stage = StageInput {
            queue: true,
            ..with_lyrics(5120.0, 1440.0, LyricsStyle::Auto)
        };
        let arrangement = arrange(stage);
        assert_eq!(arrangement.placement(), Some(Placement::Beside));
        let (queue, floating) = arrangement.queue.unwrap();
        assert!(!floating);
        assert!(!overlaps(queue, arrangement.video));
        assert!(queue.x >= arrangement.video.right());
    }

    #[test]
    fn up_next_floats_as_a_sheet_when_there_is_no_room_beside() {
        let stage = StageInput {
            queue: true,
            ..with_lyrics(1600.0, 1000.0, LyricsStyle::Auto)
        };
        let arrangement = arrange(stage);
        let (queue, floating) = arrangement.queue.unwrap();
        assert!(floating);
        assert!(queue.y >= stage.top_inset);
        assert!(queue.bottom() <= 1000.0 - stage.bottom_inset);
        assert!(queue.right() <= 1600.0);
    }

    #[test]
    fn the_card_stands_above_the_dock() {
        let stage = input(1920.0, 1080.0);
        let card = arrange(stage).card.unwrap();
        assert!(!card.from_top);
        assert!(card.y <= 1080.0 - stage.bottom_inset);
    }

    #[test]
    fn with_captions_the_card_moves_to_the_top() {
        let card = arrange(with_lyrics(1920.0, 1080.0, LyricsStyle::Captions))
            .card
            .unwrap();
        assert!(card.from_top);
        assert!(card.y >= 46.0);
    }

    #[test]
    fn a_zero_sized_stage_arranges_nothing() {
        assert_eq!(arrange(input(0.0, 0.0)), Arrangement::default());
    }

    #[test]
    fn a_nonsense_aspect_falls_back_to_widescreen() {
        let stage = StageInput {
            aspect: f64::NAN,
            ..input(1600.0, 1000.0)
        };
        assert_eq!(arrange(stage).video, Rect::new(0.0, 50.0, 1600.0, 900.0));
    }

    #[test]
    fn lyrics_style_ids_round_trip() {
        for style in LyricsStyle::ALL {
            assert_eq!(LyricsStyle::from_id(style.id()), style);
        }
        assert_eq!(LyricsStyle::from_id("bogus"), LyricsStyle::Auto);
    }
}
