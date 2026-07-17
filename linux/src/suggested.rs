use crate::db::ScrobbleRow;
use crate::library::Track;
use crate::station;
use std::collections::HashMap;

const MAX_TRACKS: usize = 50;
const MIN_TRACKS: usize = 8;

#[derive(Clone)]
pub struct SuggestedPlaylist {
    #[allow(dead_code)]
    pub id: &'static str,
    pub title: String,
    pub subtitle: String,
    pub icon_name: &'static str,
    pub tracks: Vec<Track>,
}

/// Port of the iOS SuggestedPlaylistService: Heavy Rotation, Crate Dig,
/// On Repeat, Rediscover, and Tonight's Spin from local scrobble history
/// intersected with the tracks the user actually owns.
pub fn build(pool: &[Track], rows: &[ScrobbleRow], now_unix: i64) -> Vec<SuggestedPlaylist> {
    if pool.is_empty() || rows.is_empty() {
        return Vec::new();
    }

    let mut pool_by_key: HashMap<String, Track> = HashMap::new();
    for track in pool {
        pool_by_key
            .entry(station::track_key(&track.title, &track.artist))
            .or_insert_with(|| track.clone());
    }

    let recent_cutoff = now_unix - 90 * 86_400;
    let month_cutoff = now_unix - 30 * 86_400;

    let mut all_counts: HashMap<String, i64> = HashMap::new();
    let mut recent_counts: HashMap<String, i64> = HashMap::new();
    let mut month_counts: HashMap<String, i64> = HashMap::new();
    let mut artist_counts: HashMap<String, i64> = HashMap::new();
    for row in rows {
        let key = station::track_key(&row.title, &row.artist);
        *all_counts.entry(key.clone()).or_insert(0) += 1;
        *artist_counts.entry(row.artist.to_lowercase()).or_insert(0) += 1;
        if row.timestamp_unix >= recent_cutoff {
            *recent_counts.entry(key.clone()).or_insert(0) += 1;
        }
        if row.timestamp_unix >= month_cutoff {
            *month_counts.entry(key).or_insert(0) += 1;
        }
    }

    let mut suggestions = Vec::new();
    if let Some(heavy) = heavy_rotation(&pool_by_key, &month_counts, &all_counts) {
        suggestions.push(heavy);
    }
    if let Some(dig) = crate_dig(pool, &all_counts) {
        suggestions.push(dig);
    }
    if let Some(repeat_artist) = on_repeat(pool, &artist_counts, &all_counts) {
        suggestions.push(repeat_artist);
    }
    if let Some(rediscover) = rediscover(&pool_by_key, &all_counts, &recent_counts) {
        suggestions.push(rediscover);
    }
    if let Some(spin) = tonights_spin(pool, &all_counts, &recent_counts, now_unix) {
        suggestions.push(spin);
    }
    suggestions
}

fn ordered_owned_tracks(
    pool_by_key: &HashMap<String, Track>,
    counts: &HashMap<String, i64>,
) -> Vec<Track> {
    let mut entries: Vec<(&String, &i64)> = counts.iter().collect();
    entries.sort_by(|a, b| b.1.cmp(a.1).then_with(|| a.0.cmp(b.0)));
    entries
        .into_iter()
        .filter_map(|(key, _)| pool_by_key.get(key).cloned())
        .collect()
}

fn heavy_rotation(
    pool_by_key: &HashMap<String, Track>,
    month_counts: &HashMap<String, i64>,
    all_counts: &HashMap<String, i64>,
) -> Option<SuggestedPlaylist> {
    let use_month = month_counts.values().sum::<i64>() >= MIN_TRACKS as i64;
    let counts = if use_month { month_counts } else { all_counts };
    let subtitle = if use_month {
        "Your most-played this month"
    } else {
        "The songs you keep coming back to"
    };
    let ordered = ordered_owned_tracks(pool_by_key, counts);
    let mut tracks =
        station::spaced_by_artist(ordered.into_iter().take(MAX_TRACKS * 2).collect());
    tracks.truncate(MAX_TRACKS);
    if tracks.len() < MIN_TRACKS {
        return None;
    }
    Some(SuggestedPlaylist {
        id: "heavy-rotation",
        title: "Heavy Rotation".to_string(),
        subtitle: subtitle.to_string(),
        icon_name: "weather-clear-symbolic",
        tracks,
    })
}

fn on_repeat(
    pool: &[Track],
    artist_counts: &HashMap<String, i64>,
    all_counts: &HashMap<String, i64>,
) -> Option<SuggestedPlaylist> {
    let mut ranked: Vec<(&String, &i64)> = artist_counts.iter().collect();
    ranked.sort_by(|a, b| b.1.cmp(a.1).then_with(|| a.0.cmp(b.0)));
    for (artist_lower, _) in ranked.into_iter().take(8) {
        let owned: Vec<Track> = pool
            .iter()
            .filter(|t| t.artist.to_lowercase() == *artist_lower)
            .cloned()
            .collect();
        if owned.len() < MIN_TRACKS {
            continue;
        }
        let mut ordered = owned;
        ordered.sort_by(|a, b| {
            let ca = all_counts
                .get(&station::track_key(&a.title, &a.artist))
                .unwrap_or(&0);
            let cb = all_counts
                .get(&station::track_key(&b.title, &b.artist))
                .unwrap_or(&0);
            cb.cmp(ca)
        });
        ordered.truncate(MAX_TRACKS);
        let display_artist = ordered
            .first()
            .map(|t| t.artist.clone())
            .unwrap_or_else(|| artist_lower.clone());
        return Some(SuggestedPlaylist {
            id: "on-repeat",
            title: "On Repeat".to_string(),
            subtitle: format!("The best of {display_artist}"),
            icon_name: "media-playlist-repeat-symbolic",
            tracks: ordered,
        });
    }
    None
}

fn rediscover(
    pool_by_key: &HashMap<String, Track>,
    all_counts: &HashMap<String, i64>,
    recent_counts: &HashMap<String, i64>,
) -> Option<SuggestedPlaylist> {
    let filtered: HashMap<String, i64> = all_counts
        .iter()
        .filter(|(key, count)| **count >= 3 && recent_counts.get(*key).copied().unwrap_or(0) == 0)
        .map(|(k, v)| (k.clone(), *v))
        .collect();
    let ordered = ordered_owned_tracks(pool_by_key, &filtered);
    let mut tracks =
        station::spaced_by_artist(ordered.into_iter().take(MAX_TRACKS * 2).collect());
    tracks.truncate(MAX_TRACKS);
    if tracks.len() < MIN_TRACKS {
        return None;
    }
    Some(SuggestedPlaylist {
        id: "rediscover",
        title: "Rediscover".to_string(),
        subtitle: "Favourites you haven't heard in months".to_string(),
        icon_name: "document-open-recent-symbolic",
        tracks,
    })
}

fn crate_dig(pool: &[Track], all_counts: &HashMap<String, i64>) -> Option<SuggestedPlaylist> {
    let mut pairs: Vec<(String, String, i64)> = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for track in pool {
        let k = station::track_key(&track.title, &track.artist);
        if !seen.insert(k.clone()) {
            continue;
        }
        let count = all_counts
            .get(&k)
            .copied()
            .unwrap_or(track.play_count.max(0));
        pairs.push((track.title.clone(), track.artist.clone(), count));
    }
    let excluding = std::collections::HashSet::new();
    let tracks = station::crate_dig(pool, &pairs, &excluding, MAX_TRACKS);
    if tracks.len() < MIN_TRACKS {
        return None;
    }
    Some(SuggestedPlaylist {
        id: "crate-dig",
        title: "Crate Dig".to_string(),
        subtitle: "Deep cuts from albums you already love".to_string(),
        icon_name: "media-optical-symbolic",
        tracks,
    })
}

fn tonights_spin(
    pool: &[Track],
    all_counts: &HashMap<String, i64>,
    recent_counts: &HashMap<String, i64>,
    now_unix: i64,
) -> Option<SuggestedPlaylist> {
    let mut albums: HashMap<String, Vec<Track>> = HashMap::new();
    for track in pool {
        let k = format!(
            "{}\u{0}{}",
            track.album.to_lowercase(),
            track.artist.to_lowercase()
        );
        albums.entry(k).or_default().push(track.clone());
    }

    let day_seed = now_unix / 86_400;
    let mut candidates: Vec<(Vec<Track>, f64, String, String)> = Vec::new();
    for group in albums.values() {
        if group.len() < 5 {
            continue;
        }
        let mut ordered = group.clone();
        ordered.sort_by(|a, b| {
            a.track_number
                .cmp(&b.track_number)
                .then_with(|| a.title.to_lowercase().cmp(&b.title.to_lowercase()))
        });
        let album_plays: i64 = ordered
            .iter()
            .map(|t| {
                all_counts
                    .get(&station::track_key(&t.title, &t.artist))
                    .copied()
                    .unwrap_or(0)
            })
            .sum();
        let recent_plays: i64 = ordered
            .iter()
            .map(|t| {
                recent_counts
                    .get(&station::track_key(&t.title, &t.artist))
                    .copied()
                    .unwrap_or(0)
            })
            .sum();
        if recent_plays > 0 {
            continue;
        }
        let history_boost = if album_plays > 0 {
            (1.0 + album_plays as f64).log2()
        } else {
            0.35
        };
        let weight = history_boost * ordered.len() as f64;
        let title = ordered[0].album.clone();
        let artist = ordered[0].artist.clone();
        candidates.push((ordered, weight, title, artist));
    }
    if candidates.is_empty() {
        return None;
    }

    let ranked = station::weighted_shuffle(candidates, |candidate| {
        let mix = stable_mix(day_seed, &candidate.2, &candidate.3);
        candidate.1 * (0.5 + mix)
    });
    let pick = ranked.into_iter().next()?;
    let subtitle = if pick.3.is_empty() {
        "Full album night".to_string()
    } else {
        format!("Full album · {}", pick.3)
    };
    Some(SuggestedPlaylist {
        id: "tonights-spin",
        title: pick.2,
        subtitle,
        icon_name: "media-optical-cd-audio-symbolic",
        tracks: pick.0,
    })
}

fn stable_mix(day_seed: i64, title: &str, artist: &str) -> f64 {
    let mut hash: u64 = 5381u64.wrapping_add(day_seed as u64);
    let bytes = format!("{}\u{0}{}", title.to_lowercase(), artist.to_lowercase());
    for byte in bytes.bytes() {
        hash = hash.wrapping_shl(5).wrapping_add(hash).wrapping_add(byte as u64);
    }
    (hash % 10_000) as f64 / 10_000.0
}

#[cfg(test)]
mod tests {
    use super::*;

    fn track(title: &str, artist: &str) -> Track {
        Track {
            id: 0,
            rel_path: format!("{artist}/{title}.flac"),
            title: title.to_string(),
            artist: artist.to_string(),
            album: "A".to_string(),
            track_number: 1,
            duration: 200.0,
            codec: None,
            bit_depth: None,
            sample_rate: None,
            channels: None,
            loved: false,
            play_count: 0,
            date_added: 0,
            last_played: None,
        }
    }

    fn row(title: &str, artist: &str, ts: i64) -> ScrobbleRow {
        ScrobbleRow {
            title: title.to_string(),
            artist: artist.to_string(),
            album: "A".to_string(),
            timestamp_unix: ts,
            duration: 200,
        }
    }

    const NOW: i64 = 1_800_000_000;

    #[test]
    fn empty_inputs_produce_nothing() {
        assert!(build(&[], &[], NOW).is_empty());
        assert!(build(&[track("t", "a")], &[], NOW).is_empty());
    }

    #[test]
    fn heavy_rotation_uses_month_counts_when_enough() {
        let pool: Vec<Track> = (0..12).map(|i| format!("t{i}")).enumerate()
            .map(|(i, t)| track(&t, &format!("artist{}", i % 4)))
            .collect();
        let mut rows = Vec::new();
        for t in &pool {
            for _ in 0..2 {
                rows.push(row(&t.title, &t.artist, NOW - 86_400));
            }
        }
        let result = build(&pool, &rows, NOW);
        let heavy = result.iter().find(|p| p.id == "heavy-rotation").expect("heavy");
        assert_eq!(heavy.subtitle, "Your most-played this month");
        assert!(heavy.tracks.len() >= 8);
    }

    #[test]
    fn heavy_rotation_falls_back_to_all_time() {
        let pool: Vec<Track> = (0..12).map(|i| format!("t{i}")).enumerate()
            .map(|(i, t)| track(&t, &format!("artist{}", i % 4)))
            .collect();
        let mut rows = Vec::new();
        for t in &pool {
            rows.push(row(&t.title, &t.artist, NOW - 200 * 86_400));
        }
        let result = build(&pool, &rows, NOW);
        let heavy = result.iter().find(|p| p.id == "heavy-rotation").expect("heavy");
        assert_eq!(heavy.subtitle, "The songs you keep coming back to");
    }

    #[test]
    fn on_repeat_requires_eight_owned_tracks_by_top_artist() {
        let pool: Vec<Track> = (0..9).map(|i| track(&format!("t{i}"), "Big Artist")).collect();
        let mut rows = Vec::new();
        for t in &pool {
            rows.push(row(&t.title, &t.artist, NOW - 86_400));
        }
        let result = build(&pool, &rows, NOW);
        let repeat = result.iter().find(|p| p.id == "on-repeat").expect("on-repeat");
        assert_eq!(repeat.subtitle, "The best of Big Artist");
        assert_eq!(repeat.tracks.len(), 9);
    }

    #[test]
    fn rediscover_excludes_recently_played() {
        let old: Vec<Track> = (0..10).map(|i| track(&format!("old{i}"), &format!("a{}", i % 3))).collect();
        let fresh = track("fresh", "b");
        let mut pool = old.clone();
        pool.push(fresh.clone());
        let mut rows = Vec::new();
        for t in &old {
            for _ in 0..3 {
                rows.push(row(&t.title, &t.artist, NOW - 120 * 86_400));
            }
        }
        for _ in 0..5 {
            rows.push(row(&fresh.title, &fresh.artist, NOW - 86_400));
        }
        let result = build(&pool, &rows, NOW);
        let rediscover = result.iter().find(|p| p.id == "rediscover").expect("rediscover");
        assert!(rediscover.tracks.iter().all(|t| t.title != "fresh"));
        assert_eq!(rediscover.tracks.len(), 10);
    }
}
