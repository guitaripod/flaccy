//! Everything Home shows, worked out from the library, the play history and
//! what the person started. The page only draws a `HomeModel`; every decision
//! (what leads, what Jump Back In offers, which album an old day points at)
//! is made here from the shared rules in `flaccy_shared::home`, so it can be
//! tested without a window.

use crate::db::Db;
use crate::filters::{self, LibraryFilter};
use crate::home_state::SavedSession;
use crate::hygiene;
use crate::library::{Album, Library, Track};
use crate::suggested::SuggestedPlaylist;
use crate::ui::mosaic::AlbumRef;
use crate::ui::playlists::PlaylistCard;
use chrono::Datelike;
use flaccy_shared::home::{
    self, album_key, fold, hero, hero_mix, Availability, Block, ContextKind, Hero, HomePlay,
    Layout, OnThisDayPick, PlaybackContext, RecentContexts, RecentEntry, ResumePoint, WeekGlance,
    DAY, JUMP_BACK_IN_LIMIT, RECENTLY_ADDED_LIMIT,
};
use flaccy_shared::home_copy;
use flaccy_shared::playlist_cover;
use std::collections::{HashMap, HashSet};
use std::path::Path;

/// How many contexts are asked of the shared Jump Back In rule before the
/// ones the library can no longer open are dropped, so a few stale entries
/// never leave the list short.
const JUMP_CANDIDATES: usize = 24;
/// How far back the scrobble history is read for Jump Back In.
const HISTORY_DAYS: i64 = 90;
/// The first year a play can belong to a day (`home::EARLIEST_DATED`).
const FIRST_YEAR: i32 = 2002;
/// Days either side of a year ago that "A year ago this week" reads.
const WEEK_SPAN: i64 = 4;
/// Days either side of a calendar day that are fetched, so the exact local
/// day is decided by the shared rule and not by a time-zone guess here.
const DAY_MARGIN: i64 = 1;

/// Finds the library album something refers to by name: a playback context's
/// id, or the album and artist of a scrobble.
pub struct AlbumIndex {
    by_key: HashMap<String, usize>,
    by_title: HashMap<String, Vec<usize>>,
    by_path: HashMap<String, (usize, usize)>,
}

impl AlbumIndex {
    pub fn new(library: &Library) -> AlbumIndex {
        let mut by_key = HashMap::new();
        let mut by_title: HashMap<String, Vec<usize>> = HashMap::new();
        let mut by_path = HashMap::new();
        for (position, album) in library.albums.iter().enumerate() {
            by_key
                .entry(album_key(&album.title, &album.artist))
                .or_insert(position);
            by_title
                .entry(fold(&album.title))
                .or_default()
                .push(position);
            for (track_position, track) in album.tracks.iter().enumerate() {
                by_key
                    .entry(album_key(&track.album, track.credit()))
                    .or_insert(position);
                by_path.insert(track.rel_path.clone(), (position, track_position));
            }
        }
        AlbumIndex {
            by_key,
            by_title,
            by_path,
        }
    }

    /// The album a `PlaybackContext` of kind album was started from.
    pub fn album_for_context_id<'a>(&self, library: &'a Library, id: &str) -> Option<&'a Album> {
        self.by_key
            .get(id)
            .and_then(|index| library.albums.get(*index))
    }

    /// The album a play of `album` by `artist` belongs to: the exact release
    /// when the credit matches, else the one album of that title that has a
    /// song by the artist, else the only album of that title.
    pub fn resolve<'a>(
        &self,
        library: &'a Library,
        album: &str,
        artist: &str,
    ) -> Option<&'a Album> {
        if let Some(found) = self.album_for_context_id(library, &album_key(album, artist)) {
            return Some(found);
        }
        let candidates = self.by_title.get(&fold(album))?;
        let wanted = fold(artist);
        let by_artist = candidates.iter().find(|index| {
            library.albums.get(**index).is_some_and(|candidate| {
                candidate
                    .tracks
                    .iter()
                    .any(|track| fold(&track.artist) == wanted)
            })
        });
        match (by_artist, candidates.as_slice()) {
            (Some(index), _) => library.albums.get(*index),
            (None, [only]) => library.albums.get(*only),
            _ => None,
        }
    }

    pub fn track<'a>(&self, library: &'a Library, rel_path: &str) -> Option<&'a Track> {
        let (album, track) = self.by_path.get(rel_path)?;
        library.albums.get(*album)?.tracks.get(*track)
    }

    /// The (title, artist) the cover of the album holding `rel_path` is
    /// cached under.
    fn cover_of(&self, library: &Library, rel_path: &str) -> Option<AlbumRef> {
        let (album, _) = self.by_path.get(rel_path)?;
        let album = library.albums.get(*album)?;
        Some((album.title.clone(), album.artist.clone()))
    }

    /// The albums whose covers make up the mosaic of `tracks`.
    pub fn covers_of(&self, library: &Library, tracks: &[Track]) -> Vec<AlbumRef> {
        let all: Vec<AlbumRef> = tracks
            .iter()
            .filter_map(|track| self.cover_of(library, &track.rel_path))
            .collect();
        playlist_cover::mosaic_albums(&all)
    }
}

/// What the database tells Home, read off the main thread.
#[derive(Clone, Default)]
pub struct Fetched {
    pub albums: Vec<(String, String, i64)>,
    pub on_this_day: Vec<HomePlay>,
    pub week: Vec<HomePlay>,
    pub mixes: Vec<SuggestedPlaylist>,
}

/// Reads the history Home needs. The scrobble table can hold well over a
/// hundred thousand rows, so nothing here scans it: each question is a few
/// timestamp ranges. The suggested mixes read all of it, as they always have,
/// and are only recomputed when `with_mixes` says the library or the history
/// changed.
pub fn fetch(
    db_path: &Path,
    pool: Vec<Track>,
    previous_mixes: Vec<SuggestedPlaylist>,
    with_mixes: bool,
    now: i64,
    offset: i32,
) -> Fetched {
    let Ok(db) = Db::open(db_path) else {
        return Fetched::default();
    };
    let albums = db.recent_album_plays(now - HISTORY_DAYS * DAY, 200);
    let on_this_day = on_this_day_ranges(now, offset)
        .into_iter()
        .flat_map(|(from, to)| db.fetch_scrobble_rows_between(from, to))
        .map(|row| HomePlay {
            album: row.album,
            artist: row.artist,
            at: row.timestamp_unix,
            seconds: row.duration,
        })
        .collect();
    let week = db
        .fetch_scrobble_rows_since(now - 2 * home::WEEK_WINDOW)
        .into_iter()
        .map(|row| HomePlay {
            album: row.album,
            artist: row.artist,
            at: row.timestamp_unix,
            seconds: row.duration,
        })
        .collect();
    let mixes = if with_mixes {
        crate::suggested::build(&pool, &db.fetch_all_scrobble_rows(), now)
    } else {
        previous_mixes
    };
    Fetched {
        albums,
        on_this_day,
        week,
        mixes,
    }
}

/// The unix ranges that can hold today's date in an earlier year, and the days
/// around today a year ago, merged so no scrobble is read twice.
pub fn on_this_day_ranges(now: i64, offset: i32) -> Vec<(i64, i64)> {
    let today = home::local(now, offset).date_naive();
    let midnight = |date: chrono::NaiveDate| {
        date.and_hms_opt(0, 0, 0)
            .map(|time| time.and_utc().timestamp() - offset as i64)
    };
    let mut ranges = Vec::new();
    for year in FIRST_YEAR..today.year() {
        let Some(start) =
            chrono::NaiveDate::from_ymd_opt(year, today.month(), today.day()).and_then(midnight)
        else {
            continue;
        };
        ranges.push((start - DAY_MARGIN * DAY, start + (1 + DAY_MARGIN) * DAY));
    }
    if let Some(anchor) = today.with_year(today.year() - 1).and_then(midnight) {
        ranges.push((anchor - WEEK_SPAN * DAY, anchor + (WEEK_SPAN + 1) * DAY));
    }
    merge_ranges(ranges)
}

/// Sorts `[from, to)` ranges and joins the ones that touch or overlap.
pub fn merge_ranges(mut ranges: Vec<(i64, i64)>) -> Vec<(i64, i64)> {
    ranges.sort_unstable();
    let mut merged: Vec<(i64, i64)> = Vec::new();
    for (from, to) in ranges {
        match merged.last_mut() {
            Some(last) if from <= last.1 => last.1 = last.1.max(to),
            _ => merged.push((from, to)),
        }
    }
    merged
}

/// Where a Home card or row leads.
#[derive(Clone)]
pub enum Target {
    Album(Album),
    Playlist(i64),
    Mix { id: String, tracks: Vec<Track> },
    Radio(PlaybackContext),
}

/// The picture on a cover: one album's art, a playlist's own cover, or a
/// mosaic of up to four albums.
#[derive(Clone)]
pub enum Cover {
    Album(AlbumRef),
    Playlist {
        id: i64,
        name: String,
        albums: Vec<AlbumRef>,
    },
    Mosaic {
        seed: String,
        albums: Vec<AlbumRef>,
    },
}

impl Cover {
    fn key(&self) -> String {
        match self {
            Cover::Album((title, artist)) => format!("a:{title}|{artist}"),
            Cover::Playlist { id, albums, .. } => format!("p:{id}:{albums:?}"),
            Cover::Mosaic { seed, albums } => format!("m:{seed}:{albums:?}"),
        }
    }

    /// The album whose art colours the page behind the hero.
    pub fn lead(&self) -> Option<&AlbumRef> {
        match self {
            Cover::Album(album) => Some(album),
            Cover::Playlist { albums, .. } | Cover::Mosaic { albums, .. } => albums.first(),
        }
    }
}

pub struct ResumeHero {
    pub kicker: String,
    pub cover: Cover,
    pub title: String,
    pub artist: Option<String>,
    pub subtitle: String,
    pub quality: Option<String>,
    pub meta: Option<String>,
    pub segments: Vec<f64>,
    pub track_line: String,
    pub remaining: String,
    pub target: Target,
}

pub struct MixHero {
    pub id: String,
    pub kicker: String,
    pub title: String,
    pub subtitle: String,
    pub meta: String,
    pub starts_with: Option<String>,
    pub tracks: Vec<Track>,
    pub cover: Cover,
}

pub struct DayOneHero {
    pub cover: Cover,
    pub counts: String,
    pub hi_res: Option<String>,
}

pub enum HeroModel {
    Resume(Box<ResumeHero>),
    UpNext(Box<MixHero>),
    DayOne(DayOneHero),
    Empty,
}

#[derive(Clone)]
pub struct JumpItem {
    pub context: PlaybackContext,
    pub title: String,
    pub subtitle: String,
    pub cover: Cover,
    pub target: Target,
}

#[derive(Clone)]
pub enum MixKind {
    Mix(String),
    LibraryRadio,
}

#[derive(Clone)]
pub struct MixCard {
    pub kind: MixKind,
    pub title: String,
    pub subtitle: String,
    pub songs: usize,
    pub tracks: Vec<Track>,
    pub cover: Cover,
}

#[derive(Clone)]
pub struct AlbumCard {
    pub album: Album,
    pub badge: Option<String>,
}

pub struct OtdCard {
    pub title: String,
    pub subtitle: String,
    pub album: Album,
}

pub struct HomeModel {
    pub facts: Availability,
    pub blocks: Vec<Block>,
    pub hero: HeroModel,
    pub jump: Vec<JumpItem>,
    pub mixes: Vec<MixCard>,
    pub recent: Vec<AlbumCard>,
    pub otd: Option<OtdCard>,
    pub week: WeekGlance,
    pub downloads: usize,
    pub hero_lead: Option<AlbumRef>,
}

pub struct Inputs<'a> {
    pub library: &'a Library,
    pub index: &'a AlbumIndex,
    pub fetched: &'a Fetched,
    pub session: Option<&'a SavedSession>,
    pub recents: &'a RecentContexts,
    pub playlists: &'a [PlaylistCard],
    pub layout: &'a Layout,
    pub has_history: bool,
    pub is_playing: bool,
    pub downloads: usize,
    pub now: i64,
    pub offset: i32,
}

pub fn compose(inputs: &Inputs) -> HomeModel {
    let library = inputs.library;
    let resume = resume_hero(inputs);
    let mixes = mix_cards(inputs);
    let recent = recently_added(inputs);
    let otd = on_this_day_card(inputs);
    let week = WeekGlance::compute(&inputs.fetched.week, inputs.now, inputs.offset);

    let mut facts = Availability {
        library_track_count: library.tracks.len(),
        has_listening_history: inputs.has_history,
        is_playing: inputs.is_playing,
        can_resume: resume.is_some(),
        jump_back_in_count: 0,
        recently_added_count: recent.len(),
        has_on_this_day: otd.is_some(),
        has_week_plays: week.has_plays(),
    };

    let hero_mix_id = hero_mix(
        &inputs
            .fetched
            .mixes
            .iter()
            .map(|mix| mix.id)
            .collect::<Vec<&str>>(),
    );
    let (hero_model, excluded) = match hero(&facts) {
        Hero::Empty => (HeroModel::Empty, HashSet::new()),
        Hero::Resume => match resume {
            Some((hero, key)) => (HeroModel::Resume(Box::new(hero)), HashSet::from([key])),
            None => (HeroModel::Empty, HashSet::new()),
        },
        Hero::UpNext => match hero_mix_id.and_then(|id| mix_hero(inputs, id)) {
            Some(hero) => {
                let key = format!("mix:{}", hero.id);
                (HeroModel::UpNext(Box::new(hero)), HashSet::from([key]))
            }
            None => (day_one(inputs), HashSet::new()),
        },
        Hero::DayOne => (day_one(inputs), HashSet::new()),
    };

    let jump = jump_items(inputs, &mixes, &excluded);
    facts.jump_back_in_count = jump.len();
    let hero_lead = match &hero_model {
        HeroModel::Resume(hero) => hero.cover.lead().cloned(),
        HeroModel::UpNext(hero) => hero.cover.lead().cloned(),
        HeroModel::DayOne(hero) => hero.cover.lead().cloned(),
        HeroModel::Empty => None,
    };
    HomeModel {
        blocks: home::blocks(inputs.layout, &facts),
        facts,
        hero: hero_model,
        jump,
        mixes,
        recent,
        otd,
        week,
        downloads: inputs.downloads,
        hero_lead,
    }
}

fn day_one(inputs: &Inputs) -> HeroModel {
    let library = inputs.library;
    let hi_res = library
        .tracks
        .iter()
        .filter(|track| {
            home_copy::is_hi_res(
                hygiene::is_lossless(track.codec.as_deref()),
                track.bit_depth,
                track.sample_rate,
            )
        })
        .count();
    let albums: Vec<AlbumRef> = library
        .albums
        .iter()
        .take(4)
        .map(|album| (album.title.clone(), album.artist.clone()))
        .collect();
    HeroModel::DayOne(DayOneHero {
        cover: Cover::Mosaic {
            seed: "Library".to_string(),
            albums,
        },
        counts: home_copy::day_one_counts(library.tracks.len(), library.albums.len()),
        hi_res: home_copy::hi_res_line(hi_res),
    })
}

/// The hero for a session that can still be picked up, with the context key
/// Jump Back In must leave out, or `None` when there is nothing to resume.
fn resume_hero(inputs: &Inputs) -> Option<(ResumeHero, String)> {
    let saved = inputs.session?;
    let library = inputs.library;
    let index = inputs.index;
    let plan = saved.surviving(|rel| index.track(library, rel).map(|track| track.duration))?;
    let point: ResumePoint = plan.resume_point(saved.saved_at);
    if !point.is_resumable(inputs.now) {
        return None;
    }
    let tracks: Vec<Track> = plan
        .tracks
        .iter()
        .filter_map(|saved| index.track(library, &saved.rel_path).cloned())
        .collect();
    let current = tracks.get(plan.index)?;
    let context = &saved.context;
    let songs = tracks.len();
    let covers = index.covers_of(library, &tracks);

    let album = (context.kind == ContextKind::Album)
        .then(|| index.album_for_context_id(library, &context.id))
        .flatten();
    let playlist = (context.kind == ContextKind::Playlist)
        .then(|| {
            context
                .id
                .parse::<i64>()
                .ok()
                .and_then(|id| inputs.playlists.iter().find(|card| card.id == id))
        })
        .flatten();

    let (title, cover, artist, subtitle, quality, meta, target) = if let Some(album) = album {
        let meta = [album.year.clone(), album.genre.clone()]
            .into_iter()
            .flatten()
            .filter(|text| !text.is_empty())
            .collect::<Vec<_>>()
            .join(" · ");
        (
            album.title.clone(),
            Cover::Album((album.title.clone(), album.artist.clone())),
            Some(album.artist.clone()),
            album.artist.clone(),
            crate::ui::albums::album_quality_summary(album),
            (!meta.is_empty()).then_some(meta),
            Target::Album(album.clone()),
        )
    } else if let Some(card) = playlist {
        (
            card.name.clone(),
            Cover::Playlist {
                id: card.id,
                name: card.name.clone(),
                albums: card.covers.clone(),
            },
            None,
            home_copy::jump_subtitle(context, card.tracks),
            None,
            None,
            Target::Playlist(card.id),
        )
    } else {
        let named = !context.title.trim().is_empty() && context.kind != ContextKind::Queue;
        let title = if named {
            context.title.clone()
        } else {
            home_copy::YOUR_QUEUE.to_string()
        };
        let target = Target::Radio(context.clone());
        (
            title.clone(),
            Cover::Mosaic {
                seed: title,
                albums: covers,
            },
            None,
            if named {
                home_copy::jump_subtitle(context, songs)
            } else {
                home_copy::song_count(songs)
            },
            None,
            None,
            target,
        )
    };

    let recency = home::recency(saved.saved_at, inputs.now, inputs.offset);
    let hero = ResumeHero {
        kicker: home_copy::resume_kicker(recency, inputs.offset),
        cover,
        title,
        artist,
        subtitle,
        quality,
        meta,
        segments: point.segments(),
        track_line: home_copy::resume_track_line(plan.index, &current.title),
        remaining: home_copy::remaining_text(point.remaining_seconds()),
        target,
    };
    Some((hero, context.key()))
}

fn mix_hero(inputs: &Inputs, id: &str) -> Option<MixHero> {
    let mix = inputs.fetched.mixes.iter().find(|mix| mix.id == id)?;
    let albums = distinct_album_titles(inputs, &mix.tracks);
    let covers = inputs.index.covers_of(inputs.library, &mix.tracks);
    Some(MixHero {
        id: mix.id.to_string(),
        kicker: home_copy::up_next_kicker(inputs.is_playing).to_string(),
        title: mix.title.clone(),
        subtitle: mix.subtitle.clone(),
        meta: home_copy::mix_meta(
            mix.tracks.len(),
            mix.tracks.iter().map(|track| track.duration).sum(),
        ),
        starts_with: home_copy::starts_with(&albums),
        tracks: mix.tracks.clone(),
        cover: Cover::Mosaic {
            seed: mix.title.clone(),
            albums: covers,
        },
    })
}

/// The first four distinct albums a queue passes through, by title.
fn distinct_album_titles(inputs: &Inputs, tracks: &[Track]) -> Vec<String> {
    let mut seen = HashSet::new();
    let mut titles = Vec::new();
    for track in tracks {
        let title = inputs
            .index
            .cover_of(inputs.library, &track.rel_path)
            .map(|(title, _)| title)
            .unwrap_or_else(|| track.album.clone());
        if title.is_empty() || !seen.insert(fold(&title)) {
            continue;
        }
        titles.push(title);
        if titles.len() == 4 {
            break;
        }
    }
    titles
}

fn mix_cards(inputs: &Inputs) -> Vec<MixCard> {
    if inputs.library.tracks.is_empty() {
        return Vec::new();
    }
    let mut cards: Vec<MixCard> = inputs
        .fetched
        .mixes
        .iter()
        .map(|mix| MixCard {
            kind: MixKind::Mix(mix.id.to_string()),
            title: mix.title.clone(),
            subtitle: mix.subtitle.clone(),
            songs: mix.tracks.len(),
            tracks: mix.tracks.clone(),
            cover: Cover::Mosaic {
                seed: mix.title.clone(),
                albums: inputs.index.covers_of(inputs.library, &mix.tracks),
            },
        })
        .collect();
    let radio_albums: Vec<AlbumRef> = inputs
        .library
        .albums
        .iter()
        .take(4)
        .map(|album| (album.title.clone(), album.artist.clone()))
        .collect();
    cards.push(MixCard {
        kind: MixKind::LibraryRadio,
        title: home_copy::LIBRARY_RADIO_TITLE.to_string(),
        subtitle: home_copy::LIBRARY_RADIO_SUBTITLE.to_string(),
        songs: 0,
        tracks: Vec::new(),
        cover: Cover::Mosaic {
            seed: home_copy::LIBRARY_RADIO_TITLE.to_string(),
            albums: radio_albums,
        },
    });
    cards
}

fn jump_items(inputs: &Inputs, mixes: &[MixCard], excluded: &HashSet<String>) -> Vec<JumpItem> {
    let library = inputs.library;
    let history: Vec<RecentEntry> = inputs
        .fetched
        .albums
        .iter()
        .filter_map(|(title, artist, at)| {
            let album = inputs.index.resolve(library, title, artist)?;
            Some(RecentEntry {
                context: crate::app::album_context(&album.title, &album.artist),
                played_at: *at,
            })
        })
        .collect();
    let picks = home::jump_back_in(&inputs.recents.entries, &history, excluded, JUMP_CANDIDATES);
    picks
        .into_iter()
        .filter_map(|context| jump_item(inputs, mixes, context))
        .take(JUMP_BACK_IN_LIMIT)
        .collect()
}

fn jump_item(inputs: &Inputs, mixes: &[MixCard], context: PlaybackContext) -> Option<JumpItem> {
    let library = inputs.library;
    match context.kind {
        ContextKind::Album => {
            let album = inputs.index.album_for_context_id(library, &context.id)?;
            Some(JumpItem {
                title: album.title.clone(),
                subtitle: home_copy::jump_subtitle(&context, album.tracks.len()),
                cover: Cover::Album((album.title.clone(), album.artist.clone())),
                target: Target::Album(album.clone()),
                context: PlaybackContext {
                    subtitle: album.artist.clone(),
                    ..context
                },
            })
        }
        ContextKind::Playlist => {
            let id = context.id.parse::<i64>().ok()?;
            let card = inputs.playlists.iter().find(|card| card.id == id)?;
            if card.tracks == 0 {
                return None;
            }
            Some(JumpItem {
                title: card.name.clone(),
                subtitle: home_copy::jump_subtitle(&context, card.tracks),
                cover: Cover::Playlist {
                    id,
                    name: card.name.clone(),
                    albums: card.covers.clone(),
                },
                target: Target::Playlist(id),
                context,
            })
        }
        ContextKind::Mix => {
            let card = mixes
                .iter()
                .find(|card| matches!(&card.kind, MixKind::Mix(id) if *id == context.id))?;
            Some(JumpItem {
                title: card.title.clone(),
                subtitle: home_copy::jump_subtitle(&context, card.songs),
                cover: card.cover.clone(),
                target: Target::Mix {
                    id: context.id.clone(),
                    tracks: card.tracks.clone(),
                },
                context,
            })
        }
        ContextKind::Radio => {
            let albums = radio_covers(library, &context);
            Some(JumpItem {
                title: context.title.clone(),
                subtitle: home_copy::jump_subtitle(&context, 0),
                cover: Cover::Mosaic {
                    seed: context.title.clone(),
                    albums,
                },
                target: Target::Radio(context.clone()),
                context,
            })
        }
        ContextKind::Queue => None,
    }
}

/// An artist radio wears the artist's albums; Library Radio wears the library.
fn radio_covers(library: &Library, context: &PlaybackContext) -> Vec<AlbumRef> {
    let artist = context.id.strip_prefix("artist:");
    let albums: Vec<AlbumRef> = library
        .albums
        .iter()
        .filter(|album| artist.is_none_or(|artist| fold(&album.artist) == artist))
        .take(4)
        .map(|album| (album.title.clone(), album.artist.clone()))
        .collect();
    albums
}

fn recently_added(inputs: &Inputs) -> Vec<AlbumCard> {
    let albums = &inputs.library.albums;
    let Some(allowed) = filters::albums_allowed(LibraryFilter::RecentlyAdded, albums, inputs.now)
    else {
        return Vec::new();
    };
    let mut chosen: Vec<&Album> = albums
        .iter()
        .filter(|album| allowed.contains(&album.key()))
        .collect();
    chosen.sort_by(|a, b| {
        b.added_unix()
            .cmp(&a.added_unix())
            .then_with(|| a.title.cmp(&b.title))
    });
    chosen
        .into_iter()
        .take(RECENTLY_ADDED_LIMIT)
        .map(|album| AlbumCard {
            badge: hi_res_badge(album),
            album: album.clone(),
        })
        .collect()
}

/// The quality badge of an album's first hi-res song, none for the rest:
/// the cards only call out what is better than a CD.
fn hi_res_badge(album: &Album) -> Option<String> {
    album
        .tracks
        .iter()
        .find(|track| {
            home_copy::is_hi_res(
                hygiene::is_lossless(track.codec.as_deref()),
                track.bit_depth,
                track.sample_rate,
            )
        })
        .and_then(|track| track.quality_badge())
}

fn on_this_day_card(inputs: &Inputs) -> Option<OtdCard> {
    let library = inputs.library;
    let playable: Vec<HomePlay> = inputs
        .fetched
        .on_this_day
        .iter()
        .filter(|play| {
            inputs
                .index
                .resolve(library, &play.album, &play.artist)
                .is_some()
        })
        .cloned()
        .collect();
    let pick: OnThisDayPick = home::on_this_day(&playable, inputs.now, inputs.offset)?;
    let album = inputs.index.resolve(library, &pick.album, &pick.artist)?;
    Some(OtdCard {
        title: home_copy::on_this_day_title(pick.kind, pick.year),
        subtitle: home_copy::on_this_day_subtitle(&album.title, pick.plays),
        album: album.clone(),
    })
}

impl HomeModel {
    /// Everything the page draws, boiled down to text: two models with the
    /// same fingerprint look the same, so the page leaves its widgets alone.
    pub fn fingerprint(&self) -> String {
        let mut parts: Vec<String> = vec![format!("{:?}", self.blocks)];
        match &self.hero {
            HeroModel::Resume(hero) => parts.push(format!(
                "resume|{}|{}|{}|{}|{}|{:?}|{}|{}",
                hero.kicker,
                hero.title,
                hero.subtitle,
                hero.track_line,
                hero.remaining,
                hero.segments,
                hero.cover.key(),
                hero.meta.clone().unwrap_or_default()
            )),
            HeroModel::UpNext(hero) => parts.push(format!(
                "next|{}|{}|{}|{}|{}|{}",
                hero.kicker,
                hero.id,
                hero.meta,
                hero.starts_with.clone().unwrap_or_default(),
                hero.cover.key(),
                hero.tracks.len()
            )),
            HeroModel::DayOne(hero) => parts.push(format!(
                "day|{}|{}",
                hero.counts,
                hero.hi_res.clone().unwrap_or_default()
            )),
            HeroModel::Empty => parts.push("empty".to_string()),
        }
        for item in &self.jump {
            parts.push(format!(
                "j|{}|{}|{}|{}",
                item.context.key(),
                item.title,
                item.subtitle,
                item.cover.key()
            ));
        }
        for card in &self.mixes {
            parts.push(format!(
                "m|{}|{}|{}",
                card.title,
                card.songs,
                card.cover.key()
            ));
        }
        for card in &self.recent {
            parts.push(format!(
                "r|{}|{}",
                card.album.key(),
                card.badge.clone().unwrap_or_default()
            ));
        }
        if let Some(otd) = &self.otd {
            parts.push(format!(
                "o|{}|{}|{}",
                otd.title,
                otd.subtitle,
                otd.album.key()
            ));
        }
        parts.push(format!(
            "w|{}|{}|{:?}|{:?}",
            self.week.plays,
            self.week.seconds,
            self.week.daily,
            self.week.plays_delta()
        ));
        parts.push(format!("d|{}", self.downloads));
        parts.join("\n")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::home_state::SavedTrack;
    use crate::library::TrackRow;
    use chrono::{TimeZone, Utc};
    use flaccy_shared::home::Section;

    const NOW: i64 = 1_792_929_600;

    fn track(album: &str, artist: &str, number: i32, added: i64) -> Track {
        TrackRow {
            id: 0,
            rel_path: format!("{artist}/{album}/{number:02}.flac"),
            title: format!("{album} {number}"),
            artist: artist.to_string(),
            album: album.to_string(),
            album_artist: Some(artist.to_string()),
            track_number: number,
            duration: 200.0,
            codec: Some("FLAC".to_string()),
            bit_depth: Some(16),
            sample_rate: Some(44_100),
            channels: Some(2),
            loved: false,
            play_count: 0,
            date_added: added,
            last_played: None,
        }
    }

    fn album(title: &str, artist: &str, tracks: i32, added: i64) -> Album {
        Album {
            title: title.to_string(),
            artist: artist.to_string(),
            year: Some("2021".to_string()),
            genre: Some("Progressive".to_string()),
            tracks: (1..=tracks)
                .map(|number| track(title, artist, number, added))
                .collect(),
        }
    }

    fn library(albums: Vec<Album>) -> Library {
        Library {
            tracks: albums.iter().flat_map(|a| a.tracks.clone()).collect(),
            albums,
            artists: Vec::new(),
        }
    }

    struct Fixture {
        library: Library,
        index: AlbumIndex,
        fetched: Fetched,
        session: Option<SavedSession>,
        recents: RecentContexts,
        layout: Layout,
        has_history: bool,
        is_playing: bool,
    }

    impl Fixture {
        fn new(albums: Vec<Album>) -> Fixture {
            let library = library(albums);
            Fixture {
                index: AlbumIndex::new(&library),
                library,
                fetched: Fetched::default(),
                session: None,
                recents: RecentContexts::default(),
                layout: Layout::standard(),
                has_history: false,
                is_playing: false,
            }
        }

        fn model(&self) -> HomeModel {
            compose(&Inputs {
                library: &self.library,
                index: &self.index,
                fetched: &self.fetched,
                session: self.session.as_ref(),
                recents: &self.recents,
                playlists: &[],
                layout: &self.layout,
                has_history: self.has_history,
                is_playing: self.is_playing,
                downloads: 0,
                now: NOW,
                offset: 0,
            })
        }

        fn session_on(&mut self, album: &Album, index: usize, elapsed: f64, ago: i64) {
            self.session = Some(SavedSession {
                saved_at: NOW - ago,
                tracks: album
                    .tracks
                    .iter()
                    .map(|t| SavedTrack {
                        rel_path: t.rel_path.clone(),
                        duration: t.duration,
                    })
                    .collect(),
                index,
                elapsed,
                context: crate::app::album_context(&album.title, &album.artist),
            });
        }
    }

    #[test]
    fn an_empty_library_leads_with_nothing_and_shows_no_sections() {
        let model = Fixture::new(Vec::new()).model();
        assert!(matches!(model.hero, HeroModel::Empty));
        assert!(model.blocks.is_empty());
    }

    #[test]
    fn a_library_with_no_history_leads_with_day_one() {
        let model = Fixture::new(vec![album("Midnatt", "Solveig", 3, NOW)]).model();
        let HeroModel::DayOne(hero) = &model.hero else {
            panic!("expected day one");
        };
        assert_eq!(hero.counts, "3 songs · 1 album");
        assert!(hero.hi_res.is_none());
    }

    #[test]
    fn a_paused_session_leads_with_resume_and_describes_the_place() {
        let mut fixture = Fixture::new(vec![album("Progress", "Hollowmen", 5, NOW)]);
        let hollow = fixture.library.albums[0].clone();
        fixture.session_on(&hollow, 4, 20.0, 3 * 3600);
        let model = fixture.model();
        let HeroModel::Resume(hero) = &model.hero else {
            panic!("expected resume");
        };
        assert_eq!(hero.title, "Progress");
        assert_eq!(hero.artist.as_deref(), Some("Hollowmen"));
        assert_eq!(hero.meta.as_deref(), Some("2021 · Progressive"));
        assert_eq!(hero.track_line, "5 · Progress 5");
        assert_eq!(hero.remaining, "3 min left");
        assert_eq!(hero.kicker, "Continue · earlier today");
        assert_eq!(hero.segments.len(), 5);
        assert_eq!(hero.segments[4], 0.1);
    }

    #[test]
    fn playing_music_moves_the_hero_to_the_up_next_mix() {
        let mut fixture = Fixture::new(vec![album("Progress", "Hollowmen", 5, NOW)]);
        let hollow = fixture.library.albums[0].clone();
        fixture.session_on(&hollow, 1, 20.0, 600);
        fixture.has_history = true;
        fixture.is_playing = true;
        fixture.fetched.mixes = vec![SuggestedPlaylist {
            id: "on-repeat",
            title: "On Repeat".into(),
            subtitle: "Hollowmen".into(),
            icon_name: "x",
            tracks: hollow.tracks.clone(),
        }];
        let model = fixture.model();
        let HeroModel::UpNext(hero) = &model.hero else {
            panic!("expected up next");
        };
        assert_eq!(hero.title, "On Repeat");
        assert_eq!(hero.kicker, "Up next · made for you");
        assert_eq!(hero.starts_with.as_deref(), Some("Starts with Progress"));
        assert_eq!(hero.meta, "5 songs · 17 min");
    }

    #[test]
    fn a_stale_session_does_not_resume() {
        let mut fixture = Fixture::new(vec![album("Progress", "Hollowmen", 5, NOW)]);
        let hollow = fixture.library.albums[0].clone();
        fixture.session_on(&hollow, 1, 20.0, 15 * 86_400);
        assert!(matches!(fixture.model().hero, HeroModel::DayOne(_)));
    }

    #[test]
    fn jump_back_in_leaves_out_the_hero_and_what_the_library_lost() {
        let mut fixture = Fixture::new(vec![
            album("Progress", "Hollowmen", 5, NOW - 400 * 86_400),
            album("Midnatt", "Solveig", 3, NOW - 400 * 86_400),
        ]);
        let hollow = fixture.library.albums[0].clone();
        fixture.session_on(&hollow, 1, 20.0, 600);
        fixture.recents = fixture
            .recents
            .recording(crate::app::album_context("Midnatt", "Solveig"), NOW - 500)
            .recording(crate::app::album_context("Gone", "Nobody"), NOW - 400)
            .recording(
                crate::app::album_context("Progress", "Hollowmen"),
                NOW - 300,
            );
        let titles: Vec<String> = fixture
            .model()
            .jump
            .iter()
            .map(|i| i.title.clone())
            .collect();
        assert_eq!(titles, vec!["Midnatt"]);
    }

    #[test]
    fn history_albums_resolve_to_library_albums_and_fill_jump_back_in() {
        let mut fixture = Fixture::new(vec![
            album("Progress", "Hollowmen", 5, NOW - 400 * 86_400),
            album("Midnatt", "Solveig", 3, NOW - 400 * 86_400),
        ]);
        fixture.fetched.albums = vec![
            ("midnatt".into(), "SOLVEIG".into(), NOW - 100),
            ("Not Here".into(), "Anyone".into(), NOW - 50),
            ("Progress".into(), "Hollowmen".into(), NOW - 200),
        ];
        let jump = fixture.model().jump;
        let titles: Vec<&str> = jump.iter().map(|i| i.title.as_str()).collect();
        assert_eq!(titles, vec!["Midnatt", "Progress"]);
        assert_eq!(jump[0].subtitle, "Solveig");
    }

    #[test]
    fn the_index_resolves_by_credit_then_by_a_performing_artist_then_by_a_unique_title() {
        let mut compilation = album("Hits", "Various Artists", 2, 0);
        compilation.tracks[0].artist = "Solveig".into();
        let fixture = Fixture::new(vec![compilation, album("Hits", "Other", 2, 0)]);
        let found = |title: &str, artist: &str| {
            fixture
                .index
                .resolve(&fixture.library, title, artist)
                .map(|album| album.artist.clone())
        };
        assert_eq!(found("Hits", "Other"), Some("Other".to_string()));
        assert_eq!(
            found("hits", "solveig"),
            Some("Various Artists".to_string())
        );
        assert_eq!(found("Hits", "Stranger"), None);
        assert_eq!(found("Missing", "Other"), None);
    }

    #[test]
    fn recently_added_is_the_newest_twelve_with_a_badge_for_hi_res_only() {
        let mut albums: Vec<Album> = (0..15)
            .map(|n| album(&format!("Album {n:02}"), "Artist", 2, NOW - n as i64 * 3600))
            .collect();
        for track in &mut albums[0].tracks {
            track.bit_depth = Some(24);
            track.sample_rate = Some(96_000);
        }
        let fixture = Fixture::new(albums);
        let recent = fixture.model().recent;
        assert_eq!(recent.len(), 12);
        assert_eq!(recent[0].album.title, "Album 00");
        assert_eq!(recent[0].badge.as_deref(), Some("FLAC · 24/96"));
        assert!(recent[1..].iter().all(|card| card.badge.is_none()));
    }

    #[test]
    fn on_this_day_only_offers_albums_the_library_has() {
        let mut fixture = Fixture::new(vec![album("Midnatt", "Solveig", 3, NOW)]);
        let day = |year| {
            Utc.with_ymd_and_hms(year, 10, 25, 10, 0, 0)
                .unwrap()
                .timestamp()
        };
        let play = |album: &str, artist: &str, year| HomePlay {
            album: album.into(),
            artist: artist.into(),
            at: day(year),
            seconds: 100,
        };
        fixture.fetched.on_this_day = vec![
            play("Ghost", "Nobody", 2023),
            play("Ghost", "Nobody", 2023),
            play("Ghost", "Nobody", 2023),
            play("Ghost", "Nobody", 2023),
            play("Midnatt", "Solveig", 2024),
            play("Midnatt", "Solveig", 2024),
            play("Midnatt", "Solveig", 2024),
        ];
        let otd = fixture.model().otd.expect("a pick");
        assert_eq!(otd.title, "On this day in 2024");
        assert_eq!(otd.subtitle, "Midnatt, 3 plays");
    }

    #[test]
    fn merged_ranges_never_read_a_day_twice() {
        assert_eq!(
            merge_ranges(vec![(10, 20), (0, 5), (15, 30), (30, 40), (50, 60)]),
            vec![(0, 5), (10, 40), (50, 60)]
        );
        let ranges = on_this_day_ranges(NOW, 0);
        assert!(ranges.windows(2).all(|pair| pair[0].1 < pair[1].0));
        let years = home::local(NOW, 0).year() - FIRST_YEAR;
        assert!(ranges.len() as i32 <= years + 1);
    }

    #[test]
    fn this_week_counts_the_last_fourteen_days() {
        let mut fixture = Fixture::new(vec![album("Midnatt", "Solveig", 3, NOW)]);
        fixture.fetched.week = (0..10)
            .map(|n| HomePlay {
                album: "Midnatt".into(),
                artist: "Solveig".into(),
                at: NOW - n * 3600,
                seconds: 60,
            })
            .collect();
        let model = fixture.model();
        assert_eq!(model.week.plays, 10);
        assert!(model.facts.has_week_plays);
        assert!(model.blocks.contains(&Block::Single(Section::ThisWeek)));
    }

    #[test]
    fn the_fingerprint_changes_with_what_is_drawn_and_not_with_noise() {
        let mut fixture = Fixture::new(vec![album("Progress", "Hollowmen", 5, NOW)]);
        let hollow = fixture.library.albums[0].clone();
        fixture.session_on(&hollow, 1, 20.0, 600);
        let before = fixture.model().fingerprint();
        assert_eq!(fixture.model().fingerprint(), before);
        fixture.session_on(&hollow, 2, 20.0, 600);
        assert_ne!(fixture.model().fingerprint(), before);
    }

    #[test]
    fn the_layout_decides_which_sections_appear() {
        let mut fixture = Fixture::new(vec![album("Midnatt", "Solveig", 3, NOW)]);
        fixture.layout = Layout::decode(Some("madeForYou,continue|continue"));
        let blocks = fixture.model().blocks;
        assert_eq!(blocks.first(), Some(&Block::Single(Section::MadeForYou)));
        assert!(!blocks.contains(&Block::Single(Section::Resume)));
    }
}
