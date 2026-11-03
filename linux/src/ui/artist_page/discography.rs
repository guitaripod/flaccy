//! The artist's records: the two featured beside the songs (the latest release
//! and the one the person plays most), the discography newest first with a
//! chip per kind of release, and the records they appear on.

use crate::home_data::hi_res_badge;
use crate::library::{Album, Library};
use crate::ui::home_parts::{self, TileWords};
use crate::ui::{albums, context, Ui};
use adw::prelude::*;
use flaccy_shared::load_progress::group_digits;
use gtk::pango;
use std::rc::Rc;

pub const TILE_SIDE: i32 = 168;
const FEATURE_COVER: i32 = 112;
/// The industry's line between a single or EP and an album.
const ALBUM_MINUTES: f64 = 30.0;
const LONG_TRACK_MINUTES: f64 = 10.0;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ReleaseKind {
    Album,
    Ep,
    Single,
    Live,
    Compilation,
}

impl ReleaseKind {
    pub fn label(self) -> &'static str {
        match self {
            ReleaseKind::Album => "Album",
            ReleaseKind::Ep => "EP",
            ReleaseKind::Single => "Single",
            ReleaseKind::Live => "Live",
            ReleaseKind::Compilation => "Compilation",
        }
    }
}

/// The discography's chips, each gathering one or more kinds.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Shelf {
    All,
    Albums,
    SinglesAndEps,
    Live,
    Compilations,
}

impl Shelf {
    fn label(self) -> &'static str {
        match self {
            Shelf::All => "All",
            Shelf::Albums => "Albums",
            Shelf::SinglesAndEps => "Singles & EPs",
            Shelf::Live => "Live",
            Shelf::Compilations => "Compilations",
        }
    }

    fn holds(self, kind: ReleaseKind) -> bool {
        match self {
            Shelf::All => true,
            Shelf::Albums => kind == ReleaseKind::Album,
            Shelf::SinglesAndEps => matches!(kind, ReleaseKind::Single | ReleaseKind::Ep),
            Shelf::Live => kind == ReleaseKind::Live,
            Shelf::Compilations => kind == ReleaseKind::Compilation,
        }
    }
}

const SHELVES: [Shelf; 4] = [
    Shelf::Albums,
    Shelf::SinglesAndEps,
    Shelf::Live,
    Shelf::Compilations,
];

const LIVE_MARKERS: [&str; 9] = [
    "(live",
    "[live",
    "- live",
    "live at ",
    "live in ",
    "live from ",
    "unplugged",
    "in concert",
    "live!",
];

const COMPILATION_MARKERS: [&str; 7] = [
    "greatest hits",
    "best of",
    "anthology",
    "the essential",
    "the very best",
    "singles collection",
    "complete singles",
];

/// What kind of release a record is, by the rule the stores give
/// distributors: up to three songs under thirty minutes is a single (an EP if
/// one runs ten minutes or more), up to six under thirty minutes an EP, and
/// anything longer an album. Live recordings and best-ofs are told by their
/// titles first.
pub fn release_kind(title: &str, track_seconds: &[f64]) -> ReleaseKind {
    let lowered = title.to_lowercase();
    if LIVE_MARKERS.iter().any(|marker| lowered.contains(marker)) {
        return ReleaseKind::Live;
    }
    if COMPILATION_MARKERS.iter().any(|marker| lowered.contains(marker)) {
        return ReleaseKind::Compilation;
    }
    let minutes = track_seconds.iter().sum::<f64>() / 60.0;
    let longest = track_seconds.iter().copied().fold(0.0, f64::max) / 60.0;
    match track_seconds.len() {
        0 => ReleaseKind::Album,
        1..=3 if minutes < ALBUM_MINUTES && longest < LONG_TRACK_MINUTES => ReleaseKind::Single,
        1..=6 if minutes < ALBUM_MINUTES => ReleaseKind::Ep,
        _ => ReleaseKind::Album,
    }
}

pub fn album_kind(album: &Album) -> ReleaseKind {
    let lengths: Vec<f64> = album.tracks.iter().map(|track| track.duration).collect();
    release_kind(&album.title, &lengths)
}

/// The leading four-digit year of a tag like "1991" or "1991-08-12".
pub fn year_of(album: &Album) -> Option<i32> {
    let year = album.year.as_deref()?.trim();
    let digits: String = year.chars().take(4).collect();
    (digits.len() == 4 && digits.chars().all(|c| c.is_ascii_digit()))
        .then(|| digits.parse().ok())
        .flatten()
}

/// Newest first; undated records last, by title.
pub fn newest_first(library: &Library, positions: &[usize]) -> Vec<usize> {
    let mut sorted = positions.to_vec();
    sorted.sort_by(|&a, &b| {
        let (a, b) = (&library.albums[a], &library.albums[b]);
        year_of(b)
            .cmp(&year_of(a))
            .then_with(|| a.title.to_lowercase().cmp(&b.title.to_lowercase()))
    });
    sorted
}

/// How often the person has played a record, from its songs' play counts.
pub fn album_plays(album: &Album) -> i64 {
    album.tracks.iter().map(|track| track.play_count.max(0)).sum()
}

/// The newest dated release, then the one the person plays most when that is
/// another record and has been played at all.
pub fn featured(library: &Library, credited: &[usize]) -> (Option<usize>, Option<usize>) {
    let latest = credited
        .iter()
        .copied()
        .filter(|&index| year_of(&library.albums[index]).is_some())
        .max_by_key(|&index| {
            let album = &library.albums[index];
            (
                year_of(album),
                album.tracks.iter().map(|track| track.date_added).max().unwrap_or(0),
            )
        });
    let favourite = credited
        .iter()
        .copied()
        .filter(|&index| Some(index) != latest)
        .map(|index| (index, album_plays(&library.albums[index])))
        .filter(|(_, plays)| *plays > 0)
        .max_by_key(|(index, plays)| (*plays, std::cmp::Reverse(*index)))
        .map(|(index, _)| index);
    (latest, favourite)
}

fn subtitle(album: &Album, kind: ReleaseKind) -> String {
    match year_of(album) {
        Some(year) => format!("{year}  ·  {}", kind.label()),
        None => kind.label().to_string(),
    }
}

fn release_tile(ui: &Rc<Ui>, album: &Album, subtitle: &str) -> gtk::FlowBoxChild {
    let badge = hi_res_badge(album);
    let key = album.key();
    let tile = home_parts::tile(
        ui,
        &crate::home_data::Cover::Album((album.title.clone(), album.artist.clone())),
        TILE_SIDE,
        TileWords {
            title: &album.title,
            subtitle,
            badge: badge.as_deref(),
        },
        {
            let (ui, album) = (Rc::clone(ui), album.clone());
            move || albums::push_album_detail(&ui, &album)
        },
        {
            let (ui, key) = (Rc::clone(ui), key.clone());
            move || ui.core.play_album_key(&key, false)
        },
    );
    context::attach_album_context_menu(&tile, &ui.core, key);
    let child = gtk::FlowBoxChild::builder().child(&tile).focusable(false).build();
    child.add_css_class("artist-release");
    child
}

fn release_grid() -> gtk::FlowBox {
    gtk::FlowBox::builder()
        .selection_mode(gtk::SelectionMode::None)
        .homogeneous(true)
        .column_spacing(4)
        .row_spacing(10)
        .min_children_per_line(2)
        .max_children_per_line(12)
        .valign(gtk::Align::Start)
        .activate_on_single_click(false)
        .build()
}

pub fn section_heading(title: &str) -> gtk::Label {
    let heading = gtk::Label::builder()
        .label(title)
        .xalign(0.0)
        .hexpand(true)
        .ellipsize(pango::EllipsizeMode::End)
        .build();
    heading.add_css_class("title-2");
    heading.add_css_class("artist-section-title");
    heading.set_accessible_role(gtk::AccessibleRole::Heading);
    heading
}

/// The discography: a chip per kind present (plus All when there is more
/// than one), then the grid, filtered in place.
pub fn discography(ui: &Rc<Ui>, library: &Library, credited: &[usize]) -> Option<gtk::Widget> {
    if credited.is_empty() {
        return None;
    }
    let ordered = newest_first(library, credited);
    let kinds: Vec<ReleaseKind> = ordered.iter().map(|&i| album_kind(&library.albums[i])).collect();
    let section = gtk::Box::new(gtk::Orientation::Vertical, 14);
    let header = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    header.append(&section_heading("Discography"));
    section.append(&header);

    let grid = release_grid();
    for (&index, &kind) in ordered.iter().zip(&kinds) {
        let album = &library.albums[index];
        grid.append(&release_tile(ui, album, &subtitle(album, kind)));
    }

    let present: Vec<Shelf> = SHELVES
        .iter()
        .copied()
        .filter(|shelf| kinds.iter().any(|kind| shelf.holds(*kind)))
        .collect();
    if present.len() > 1 {
        let chips = adw::WrapBox::builder().child_spacing(8).line_spacing(8).build();
        chips.add_css_class("artist-chips");
        let mut leader: Option<gtk::ToggleButton> = None;
        for shelf in std::iter::once(Shelf::All).chain(present) {
            let count = kinds.iter().filter(|kind| shelf.holds(**kind)).count();
            let chip = gtk::ToggleButton::builder()
                .label(format!("{}  {}", shelf.label(), group_digits(count)))
                .active(shelf == Shelf::All)
                .build();
            chip.add_css_class("pill");
            chip.add_css_class("chip");
            chip.set_group(leader.as_ref());
            leader.get_or_insert_with(|| chip.clone());
            let grid = grid.downgrade();
            let kinds = kinds.clone();
            chip.connect_toggled(move |chip| {
                if !chip.is_active() {
                    return;
                }
                let Some(grid) = grid.upgrade() else { return };
                let kinds = kinds.clone();
                grid.set_filter_func(move |child| {
                    kinds
                        .get(child.index().max(0) as usize)
                        .is_some_and(|kind| shelf.holds(*kind))
                });
            });
            chips.append(&chip);
        }
        section.append(&chips);
    }
    section.append(&grid);
    Some(section.upcast())
}

/// The records the artist plays on without being their credit, under the
/// credit they are filed by.
pub fn appears_on(ui: &Rc<Ui>, library: &Library, positions: &[usize]) -> Option<gtk::Widget> {
    if positions.is_empty() {
        return None;
    }
    let section = gtk::Box::new(gtk::Orientation::Vertical, 14);
    section.append(&section_heading("Appears On"));
    let grid = release_grid();
    for index in newest_first(library, positions) {
        let album = &library.albums[index];
        let line = match year_of(album) {
            Some(year) => format!("{year}  ·  {}", album.artist),
            None => album.artist.clone(),
        };
        grid.append(&release_tile(ui, album, &line));
    }
    section.append(&grid);
    Some(section.upcast())
}

/// A large card for one record: its cover, what it is to the artist or to the
/// person, its title and facts, and a play button.
pub fn feature_card(ui: &Rc<Ui>, album: &Album, eyebrow: &str, detail: &str) -> gtk::Widget {
    let row = gtk::Box::new(gtk::Orientation::Horizontal, 18);
    let art = home_parts::cover(
        ui,
        &crate::home_data::Cover::Album((album.title.clone(), album.artist.clone())),
        FEATURE_COVER,
        None,
    );
    art.set_valign(gtk::Align::Center);
    row.append(&art);
    let words = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(4)
        .valign(gtk::Align::Center)
        .hexpand(true)
        .build();
    let eyebrow_label = gtk::Label::builder().label(eyebrow).xalign(0.0).build();
    eyebrow_label.add_css_class("stat-caption");
    eyebrow_label.add_css_class("artist-feature-eyebrow");
    words.append(&eyebrow_label);
    let title = gtk::Label::builder()
        .label(&album.title)
        .xalign(0.0)
        .wrap(true)
        .wrap_mode(pango::WrapMode::WordChar)
        .lines(2)
        .ellipsize(pango::EllipsizeMode::End)
        .build();
    title.add_css_class("artist-feature-title");
    words.append(&title);
    let detail_label = gtk::Label::builder()
        .label(detail)
        .xalign(0.0)
        .ellipsize(pango::EllipsizeMode::End)
        .build();
    detail_label.add_css_class("dim");
    detail_label.add_css_class("caption");
    words.append(&detail_label);
    row.append(&words);

    let open = gtk::Button::builder().child(&row).build();
    open.add_css_class("flat");
    open.add_css_class("artist-feature");
    open.update_property(&[gtk::accessible::Property::Label(&format!("{eyebrow}: {}", album.title))]);
    {
        let (ui, album) = (Rc::clone(ui), album.clone());
        open.connect_clicked(move |_| albums::push_album_detail(&ui, &album));
    }
    context::attach_album_context_menu(&open, &ui.core, album.key());

    let play = gtk::Button::from_icon_name("media-playback-start-symbolic");
    play.add_css_class("circular");
    play.add_css_class("suggested-action");
    play.add_css_class("artist-feature-play");
    play.set_halign(gtk::Align::End);
    play.set_valign(gtk::Align::Center);
    play.set_margin_end(16);
    play.set_tooltip_text(Some(&format!("Play {}", album.title)));
    play.update_property(&[gtk::accessible::Property::Label(&format!("Play {}", album.title))]);
    {
        let (ui, key) = (Rc::clone(ui), album.key());
        play.connect_clicked(move |_| ui.core.play_album_key(&key, false));
    }

    let overlay = gtk::Overlay::new();
    overlay.set_child(Some(&open));
    overlay.add_overlay(&play);
    overlay.add_css_class("artist-feature-host");
    overlay.upcast()
}

/// "2023 · Album · 12 songs".
pub fn latest_detail(album: &Album) -> String {
    let mut parts = Vec::new();
    if let Some(year) = year_of(album) {
        parts.push(year.to_string());
    }
    parts.push(album_kind(album).label().to_string());
    parts.push(songs_text(album.tracks.len()));
    parts.join("  ·  ")
}

/// "1,204 plays · 1991".
pub fn favourite_detail(album: &Album) -> String {
    let mut parts = vec![crate::ui::artist_page::listening::plays_text(album_plays(album))];
    if let Some(year) = year_of(album) {
        parts.push(year.to_string());
    }
    parts.join("  ·  ")
}

pub fn songs_text(count: usize) -> String {
    match count {
        1 => "1 song".to_string(),
        count => format!("{} songs", group_digits(count)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn minutes(lengths: &[f64]) -> Vec<f64> {
        lengths.iter().map(|m| m * 60.0).collect()
    }

    #[test]
    fn kinds_follow_the_store_rules() {
        assert_eq!(release_kind("Song", &minutes(&[3.5])), ReleaseKind::Single);
        assert_eq!(release_kind("Two", &minutes(&[3.0, 4.0, 5.0])), ReleaseKind::Single);
        assert_eq!(release_kind("Epic", &minutes(&[12.0])), ReleaseKind::Ep);
        assert_eq!(release_kind("Six", &minutes(&[4.0; 6])), ReleaseKind::Ep);
        assert_eq!(release_kind("Seven", &minutes(&[3.0; 7])), ReleaseKind::Album);
        assert_eq!(release_kind("Long Four", &minutes(&[9.0; 4])), ReleaseKind::Album);
        assert_eq!(release_kind("Empty", &[]), ReleaseKind::Album);
    }

    #[test]
    fn titles_tell_live_records_and_best_ofs() {
        let full = minutes(&[5.0; 12]);
        assert_eq!(release_kind("S&M (Live)", &full), ReleaseKind::Live);
        assert_eq!(release_kind("Live at Wembley Stadium", &full), ReleaseKind::Live);
        assert_eq!(release_kind("MTV Unplugged in New York", &full), ReleaseKind::Live);
        assert_eq!(release_kind("Greatest Hits", &full), ReleaseKind::Compilation);
        assert_eq!(release_kind("The Best of Bowie", &full), ReleaseKind::Compilation);
        assert_eq!(release_kind("Long Live", &full), ReleaseKind::Album);
        assert_eq!(release_kind("Alive", &full), ReleaseKind::Album);
        assert_eq!(release_kind("Live Forever", &full), ReleaseKind::Album);
        assert_eq!(release_kind("Alive in Paris (Live)", &full), ReleaseKind::Live);
    }

    fn album(title: &str, year: Option<&str>) -> Album {
        Album {
            title: title.to_string(),
            artist: "A".to_string(),
            year: year.map(String::from),
            genre: None,
            tracks: Vec::new(),
        }
    }

    #[test]
    fn years_read_from_the_front_of_the_tag() {
        assert_eq!(year_of(&album("x", Some("1991"))), Some(1991));
        assert_eq!(year_of(&album("x", Some("1991-08-12"))), Some(1991));
        assert_eq!(year_of(&album("x", Some(" 2004 "))), Some(2004));
        assert_eq!(year_of(&album("x", Some("19"))), None);
        assert_eq!(year_of(&album("x", Some("abcd"))), None);
        assert_eq!(year_of(&album("x", None)), None);
    }
}
