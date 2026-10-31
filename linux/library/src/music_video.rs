/// The video chosen for one library track, and how its timeline maps onto the
/// audio on disk.
#[derive(Clone)]
pub struct VideoMatch {
    pub video_id: String,
    pub title: String,
    pub channel: String,
    pub duration: f64,
    /// The video's head start over the local file where the song begins. For
    /// a match aligned before time maps existed this is the whole alignment.
    pub offset: f64,
    pub aligned: bool,
    pub chosen_by_user: bool,
    pub reason: String,
    /// How each stretch of the local file lines up with the video, so an edit
    /// that drops a verse or adds a cold open stays in sync past the cut.
    pub map: TimeMap,
    /// The listener's own correction on top of the automatic alignment, kept
    /// apart so resetting it returns to what the aligner found.
    pub trim: f64,
    /// Which aligner last listened to this pairing; an older one is re-run.
    pub align_version: i64,
}

impl VideoMatch {
    /// Where the video should be, in its own seconds, while the local file is
    /// at `local`.
    pub fn video_time(&self, local: f64) -> f64 {
        let automatic = if self.map.is_empty() {
            local + self.offset
        } else {
            self.map.video_time(local)
        };
        automatic + self.trim
    }

    /// How fast the video's timeline runs against the local file at `local`.
    pub fn rate_at(&self, local: f64) -> f64 {
        if self.map.is_empty() {
            1.0
        } else {
            self.map.segment_at(local).rate
        }
    }
}

/// One stretch of the local file that plays continuously in the video.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Segment {
    /// Where the stretch begins in the local file, in seconds.
    pub start: f64,
    /// Seconds to add to `start` to reach the same moment in the video.
    pub offset: f64,
    /// Video seconds per local second: a vinyl rip turning a fraction of a
    /// percent off speed drifts by a second over a song without it.
    pub rate: f64,
}

/// A piecewise map from the local file's timeline to the video's. Empty means
/// "no alignment"; one segment is a plain offset; each further segment is a
/// cut, an inserted scene or a dropped verse in the video's edit.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct TimeMap {
    segments: Vec<Segment>,
}

impl TimeMap {
    /// Builds a map from segments in any order, dropping ones that are not
    /// finite and keeping the first of any two that start together.
    pub fn new(mut segments: Vec<Segment>) -> Self {
        segments.retain(|segment| {
            segment.start.is_finite()
                && segment.offset.is_finite()
                && segment.rate.is_finite()
                && segment.rate > 0.0
        });
        segments.sort_by(|a, b| a.start.total_cmp(&b.start));
        segments.dedup_by(|later, earlier| (later.start - earlier.start).abs() < 1e-6);
        Self { segments }
    }

    pub fn single(offset: f64) -> Self {
        Self::new(vec![Segment {
            start: 0.0,
            offset,
            rate: 1.0,
        }])
    }

    pub fn is_empty(&self) -> bool {
        self.segments.is_empty()
    }

    pub fn segments(&self) -> &[Segment] {
        &self.segments
    }

    /// The number of places where the video's edit departs from the album.
    pub fn cuts(&self) -> usize {
        self.segments.len().saturating_sub(1)
    }

    /// The video's head start where the song begins.
    pub fn lead_offset(&self) -> f64 {
        self.segments
            .first()
            .map(|segment| segment.offset)
            .unwrap_or(0.0)
    }

    /// The segment governing `local`. Positions before the first segment
    /// belong to it, so an intro the aligner could not hear still plays.
    ///
    /// Panics on an empty map; callers check `is_empty` first.
    pub fn segment_at(&self, local: f64) -> Segment {
        let index = self
            .segments
            .partition_point(|segment| segment.start <= local)
            .saturating_sub(1);
        self.segments[index]
    }

    pub fn video_time(&self, local: f64) -> f64 {
        if self.segments.is_empty() {
            return local;
        }
        let segment = self.segment_at(local);
        segment.start + segment.offset + segment.rate * (local - segment.start)
    }

    /// The local position where the segment after the one governing `local`
    /// begins — the moment the video next jumps.
    pub fn next_cut_after(&self, local: f64) -> Option<f64> {
        self.segments
            .iter()
            .map(|segment| segment.start)
            .find(|start| *start > local)
    }

    /// Compact text for the database: `start:offset:rate` per segment.
    pub fn encode(&self) -> String {
        self.segments
            .iter()
            .map(|segment| {
                format!(
                    "{:.3}:{:.3}:{:.6}",
                    segment.start, segment.offset, segment.rate
                )
            })
            .collect::<Vec<_>>()
            .join(";")
    }

    /// Reads `encode`'s text. Anything unreadable yields an empty map, which
    /// the caller treats as "not aligned yet".
    pub fn decode(text: &str) -> Self {
        let mut segments = Vec::new();
        for part in text
            .split(';')
            .map(str::trim)
            .filter(|part| !part.is_empty())
        {
            let mut fields = part.split(':').map(|field| field.trim().parse::<f64>());
            let (Some(Ok(start)), Some(Ok(offset)), Some(Ok(rate)), None) =
                (fields.next(), fields.next(), fields.next(), fields.next())
            else {
                return Self::default();
            };
            segments.push(Segment {
                start,
                offset,
                rate,
            });
        }
        Self::new(segments)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn found(offset: f64, map: TimeMap, trim: f64) -> VideoMatch {
        VideoMatch {
            video_id: "abc".into(),
            title: String::new(),
            channel: String::new(),
            duration: 200.0,
            offset,
            aligned: true,
            chosen_by_user: false,
            reason: String::new(),
            map,
            trim,
            align_version: 0,
        }
    }

    #[test]
    fn a_cut_moves_the_video_back_by_what_the_edit_dropped() {
        let map = TimeMap::new(vec![
            Segment {
                start: 72.0,
                offset: 5.25,
                rate: 1.0,
            },
            Segment {
                start: 0.0,
                offset: 10.5,
                rate: 1.0,
            },
        ]);
        assert_eq!(map.cuts(), 1);
        assert_eq!(map.lead_offset(), 10.5);
        assert_eq!(map.video_time(10.0), 20.5);
        assert_eq!(map.video_time(80.0), 85.25);
        assert_eq!(map.next_cut_after(10.0), Some(72.0));
        assert_eq!(map.next_cut_after(80.0), None);
    }

    #[test]
    fn a_position_before_the_first_segment_belongs_to_it() {
        let map = TimeMap::new(vec![Segment {
            start: 6.0,
            offset: 3.0,
            rate: 1.0,
        }]);
        assert_eq!(map.video_time(2.0), 5.0);
    }

    #[test]
    fn a_drifting_rip_follows_its_rate() {
        let map = TimeMap::new(vec![Segment {
            start: 0.0,
            offset: 17.0,
            rate: 1.002,
        }]);
        assert!((map.video_time(300.0) - 317.6).abs() < 1e-9);
    }

    #[test]
    fn the_map_survives_the_database() {
        let map = TimeMap::new(vec![
            Segment {
                start: 0.0,
                offset: 10.571,
                rate: 1.0,
            },
            Segment {
                start: 71.93,
                offset: -5.25,
                rate: 1.001_62,
            },
        ]);
        assert_eq!(TimeMap::decode(&map.encode()), map);
        assert!(TimeMap::decode("").is_empty());
        assert!(TimeMap::decode("1:2").is_empty());
        assert!(TimeMap::decode("a:b:c").is_empty());
        assert!(TimeMap::decode("0:1:0").is_empty());
    }

    #[test]
    fn a_legacy_match_uses_its_single_offset_and_the_trim_rides_on_top() {
        let legacy = found(8.0, TimeMap::default(), 0.25);
        assert_eq!(legacy.video_time(10.0), 18.25);
        assert_eq!(legacy.rate_at(10.0), 1.0);
        let mapped = found(
            99.0,
            TimeMap::new(vec![Segment {
                start: 0.0,
                offset: 2.0,
                rate: 1.001,
            }]),
            -0.5,
        );
        assert!((mapped.video_time(100.0) - 101.6).abs() < 1e-9);
        assert_eq!(mapped.rate_at(100.0), 1.001);
    }
}
