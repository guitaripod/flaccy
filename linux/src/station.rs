use crate::library::Track;
use rand::Rng;
use std::collections::HashMap;

pub const STATION_SIZE: usize = 60;
pub const CONTINUATION_BATCH_SIZE: usize = 30;

/// Weighted random ordering (Efraimidis–Spirakis): each element gets the key
/// `u^(1/weight)` for a uniform `u`, sorted descending, so higher weights tend
/// to sort earlier while every element keeps a chance.
pub fn weighted_shuffle<T>(items: Vec<T>, weight: impl Fn(&T) -> f64) -> Vec<T> {
    let mut rng = rand::rng();
    let mut keyed: Vec<(T, f64)> = items
        .into_iter()
        .map(|element| {
            let w = weight(&element).max(0.0001);
            let u: f64 = rng.random_range(1e-12..1.0);
            let key = u.powf(1.0 / w);
            (element, key)
        })
        .collect();
    keyed.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
    keyed.into_iter().map(|(element, _)| element).collect()
}

/// Reorders tracks so the same artist rarely plays back-to-back, preserving the
/// incoming (already weighted) order within each artist.
pub fn spaced_by_artist(tracks: Vec<Track>) -> Vec<Track> {
    let mut buckets: HashMap<String, Vec<Track>> = HashMap::new();
    let mut order: Vec<String> = Vec::new();
    for track in tracks {
        let key = track.artist.to_lowercase();
        if !buckets.contains_key(&key) {
            order.push(key.clone());
        }
        buckets.entry(key).or_default().push(track);
    }
    let total: usize = buckets.values().map(|b| b.len()).sum();
    let mut result: Vec<Track> = Vec::with_capacity(total);
    let mut last_artist: Option<String> = None;
    while result.len() < total {
        let remaining_artists = order
            .iter()
            .filter(|k| !buckets.get(*k).map(|b| b.is_empty()).unwrap_or(true))
            .count();
        let mut placed = false;
        for key in &order {
            let empty = buckets.get(key).map(|b| b.is_empty()).unwrap_or(true);
            if empty {
                continue;
            }
            if last_artist.as_deref() == Some(key.as_str()) && remaining_artists > 1 {
                continue;
            }
            if let Some(bucket) = buckets.get_mut(key) {
                result.push(bucket.remove(0));
            }
            last_artist = Some(key.clone());
            placed = true;
            break;
        }
        if !placed {
            for key in &order {
                let empty = buckets.get(key).map(|b| b.is_empty()).unwrap_or(true);
                if empty {
                    continue;
                }
                if let Some(bucket) = buckets.get_mut(key) {
                    result.push(bucket.remove(0));
                }
                last_artist = Some(key.clone());
                break;
            }
        }
    }
    result
}

/// Seed-artist station: the seed's own tracks (weight 1) plus tracks by
/// similar-in-library artists, each weighted by the Last.fm match score.
pub fn artist_station(
    seed_artist: &str,
    similar_in_library: &[(String, f64)],
    pool: &[Track],
    excluding: &std::collections::HashSet<String>,
    limit: usize,
) -> Vec<Track> {
    let mut weights: HashMap<String, f64> = HashMap::new();
    weights.insert(seed_artist.to_lowercase(), 1.0);
    for (name, matched) in similar_in_library {
        weights.insert(name.to_lowercase(), matched.clamp(0.1, 0.95));
    }
    let candidates: Vec<Track> = pool
        .iter()
        .filter(|track| {
            !excluding.contains(&track.rel_path)
                && weights.contains_key(&track.artist.to_lowercase())
        })
        .cloned()
        .collect();
    if candidates.is_empty() {
        return Vec::new();
    }
    let shuffled = weighted_shuffle(candidates, |track| {
        *weights.get(&track.artist.to_lowercase()).unwrap_or(&0.1)
    });
    let mut station = spaced_by_artist(shuffled.into_iter().take(limit * 2).collect());
    station.truncate(limit);
    station
}

/// Seed-track station: an artist station for the track's artist with the seed
/// track guaranteed first, unless the seed is excluded (already queued).
pub fn track_station(
    seed_track: &Track,
    similar_in_library: &[(String, f64)],
    pool: &[Track],
    excluding: &std::collections::HashSet<String>,
    limit: usize,
) -> Vec<Track> {
    let mut station = artist_station(&seed_track.artist, similar_in_library, pool, excluding, limit);
    if !excluding.contains(&seed_track.rel_path) {
        station.retain(|t| t.rel_path != seed_track.rel_path);
        station.insert(0, seed_track.clone());
    }
    station
}

/// Most-played station: every library track weighted by its scrobble count so
/// favourites dominate while unplayed tracks still surface for variety.
pub fn library_radio(
    pool: &[Track],
    play_counts: &[(String, String, i64)],
    excluding: &std::collections::HashSet<String>,
    limit: usize,
) -> Vec<Track> {
    let mut count_by_key: HashMap<String, i64> = HashMap::new();
    for (title, artist, count) in play_counts {
        count_by_key.insert(track_key(title, artist), *count);
    }
    let candidates: Vec<Track> = pool
        .iter()
        .filter(|track| !excluding.contains(&track.rel_path))
        .cloned()
        .collect();
    if candidates.is_empty() {
        return Vec::new();
    }
    let weighted = weighted_shuffle(candidates, |track| {
        1.0 + *count_by_key
            .get(&track_key(&track.title, &track.artist))
            .unwrap_or(&0) as f64
    });
    let mut station = spaced_by_artist(weighted.into_iter().take(limit * 2).collect());
    station.truncate(limit);
    station
}

/// Crate Dig: underplayed tracks from albums the listener already knows.
pub fn crate_dig(
    pool: &[Track],
    play_counts: &[(String, String, i64)],
    excluding: &std::collections::HashSet<String>,
    limit: usize,
) -> Vec<Track> {
    let mut count_by_key: HashMap<String, i64> = HashMap::new();
    for (title, artist, count) in play_counts {
        count_by_key.insert(track_key(title, artist), *count);
    }

    let mut albums: HashMap<String, Vec<Track>> = HashMap::new();
    for track in pool {
        if excluding.contains(&track.rel_path) {
            continue;
        }
        let key = format!(
            "{}\u{0}{}",
            track.album.to_lowercase(),
            track.artist.to_lowercase()
        );
        albums.entry(key).or_default().push(track.clone());
    }

    let mut scored: Vec<(Track, f64)> = Vec::new();
    for tracks in albums.values() {
        if tracks.len() < 4 {
            continue;
        }
        let counts: Vec<i64> = tracks
            .iter()
            .map(|t| {
                *count_by_key
                    .get(&track_key(&t.title, &t.artist))
                    .unwrap_or(&t.play_count.max(0))
            })
            .collect();
        let album_plays: i64 = counts.iter().sum();
        let peak = *counts.iter().max().unwrap_or(&0);
        if album_plays < 3 || peak < 2 {
            continue;
        }
        let threshold = (peak / 3).max(0);
        for (track, count) in tracks.iter().zip(counts.iter()) {
            if *count > threshold {
                continue;
            }
            let weight =
                (album_plays as f64) / ((*count + 1) as f64) * (1.0 + (peak - *count) as f64);
            scored.push((track.clone(), weight.max(0.1)));
        }
    }
    if scored.is_empty() {
        return Vec::new();
    }

    let weight_map: HashMap<String, f64> = scored
        .iter()
        .map(|(t, w)| (t.rel_path.clone(), *w))
        .collect();
    let candidates: Vec<Track> = scored.into_iter().map(|(t, _)| t).collect();
    let weighted = weighted_shuffle(candidates, |track| {
        *weight_map.get(&track.rel_path).unwrap_or(&0.1)
    });
    let mut station = spaced_by_artist(weighted.into_iter().take(limit * 2).collect());
    station.truncate(limit);
    station
}

/// History-aware shuffle weight matching iOS: max(0.05, age/(age+3d)) where
/// age is seconds since the track's lastPlayed (never played → weight 1.0).
pub fn history_weight(last_played_unix: Option<i64>, now_unix: i64) -> f64 {
    match last_played_unix {
        None => 1.0,
        Some(last) => {
            let age = (now_unix - last).max(0) as f64;
            let three_days = 3.0 * 86_400.0;
            (age / (age + three_days)).max(0.05)
        }
    }
}

pub fn track_key(title: &str, artist: &str) -> String {
    format!("{}\u{0}{}", title.to_lowercase(), artist.to_lowercase())
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

    #[test]
    fn weighted_shuffle_preserves_all_elements() {
        let items: Vec<i32> = (0..100).collect();
        let shuffled = weighted_shuffle(items.clone(), |i| (*i as f64) + 1.0);
        assert_eq!(shuffled.len(), 100);
        let mut sorted = shuffled.clone();
        sorted.sort();
        assert_eq!(sorted, items);
    }

    #[test]
    fn weighted_shuffle_biases_high_weights_first() {
        let mut heavy_first = 0;
        for _ in 0..200 {
            let items = vec![("light", 0.01), ("heavy", 100.0)];
            let shuffled = weighted_shuffle(items, |(_, w)| *w);
            if shuffled[0].0 == "heavy" {
                heavy_first += 1;
            }
        }
        assert!(heavy_first > 180, "heavy won only {heavy_first}/200");
    }

    #[test]
    fn spaced_by_artist_avoids_back_to_back() {
        let tracks = vec![
            track("a1", "A"),
            track("a2", "A"),
            track("a3", "A"),
            track("b1", "B"),
            track("b2", "B"),
            track("c1", "C"),
        ];
        let spaced = spaced_by_artist(tracks);
        assert_eq!(spaced.len(), 6);
        let mut adjacent = 0;
        for pair in spaced.windows(2) {
            if pair[0].artist == pair[1].artist {
                adjacent += 1;
            }
        }
        assert!(adjacent <= 1, "too many adjacent same-artist pairs: {adjacent}");
    }

    #[test]
    fn spaced_by_artist_single_artist_keeps_order() {
        let tracks = vec![track("a1", "A"), track("a2", "A"), track("a3", "A")];
        let spaced = spaced_by_artist(tracks);
        let titles: Vec<&str> = spaced.iter().map(|t| t.title.as_str()).collect();
        assert_eq!(titles, vec!["a1", "a2", "a3"]);
    }

    #[test]
    fn artist_station_filters_to_seed_and_similar() {
        let pool = vec![
            track("s1", "Seed"),
            track("s2", "Seed"),
            track("m1", "Match"),
            track("x1", "Other"),
        ];
        let similar = vec![("Match".to_string(), 0.8)];
        let excluding = std::collections::HashSet::new();
        let station = artist_station("Seed", &similar, &pool, &excluding, 60);
        assert_eq!(station.len(), 3);
        assert!(station.iter().all(|t| t.artist != "Other"));
    }

    #[test]
    fn track_station_puts_seed_first() {
        let pool = vec![track("s1", "Seed"), track("s2", "Seed"), track("s3", "Seed")];
        let seed = pool[1].clone();
        let excluding = std::collections::HashSet::new();
        let station = track_station(&seed, &[], &pool, &excluding, 60);
        assert_eq!(station[0].rel_path, seed.rel_path);
        assert_eq!(station.len(), 3);
    }

    #[test]
    fn crate_dig_prefers_underplayed_tracks_on_known_albums() {
        let mut pool = Vec::new();
        for i in 0..6 {
            let mut t = track(&format!("hit{i}"), "ArtistA");
            t.album = "Loved".into();
            t.track_number = i + 1;
            pool.push(t);
        }
        for i in 0..4 {
            let mut t = track(&format!("deep{i}"), "ArtistA");
            t.album = "Loved".into();
            t.track_number = 10 + i;
            pool.push(t);
        }
        let mut other = track("only", "Other");
        other.album = "Thin".into();
        pool.push(other);

        let mut play_counts = Vec::new();
        for i in 0..6 {
            play_counts.push((format!("hit{i}"), "ArtistA".into(), 12));
        }
        for i in 0..4 {
            play_counts.push((format!("deep{i}"), "ArtistA".into(), 0));
        }
        let excluding = std::collections::HashSet::new();
        let dig = crate_dig(&pool, &play_counts, &excluding, 20);
        assert!(!dig.is_empty());
        assert!(dig.iter().all(|t| t.title.starts_with("deep")));
    }

    #[test]
    fn history_weight_floors_and_scales() {
        let now = 1_000_000_000;
        assert_eq!(history_weight(None, now), 1.0);
        assert_eq!(history_weight(Some(now), now), 0.05);
        let one_week = history_weight(Some(now - 7 * 86_400), now);
        assert!(one_week > 0.6 && one_week < 0.8);
    }
}
