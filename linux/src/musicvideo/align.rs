use flaccy_library::music_video::{Segment, TimeMap};
use std::process::{Command, Stdio};

/// Everything downstream of the decoder works at this rate. Onsets are a
/// rhythmic feature, not a timbral one, so 11 kHz carries every cue that
/// matters at a quarter of the samples.
const SAMPLE_RATE: usize = 11025;
const FRAME: usize = 1024;
const HOP: usize = 256;

/// The longest stretch of either recording examined. Whole songs, so a cut
/// late in the edit is heard; capped so a concert upload can't run for long.
const MAX_ANALYSIS_SECONDS: usize = 900;

/// Each stretch of the local file is matched on its own, this long. Long
/// enough to carry a phrase that is unlikely to repeat exactly, short enough
/// that a cut lands between two stretches rather than inside most of them.
const WINDOW_SECONDS: f64 = 10.0;

/// How far apart the stretches start. Finer than the window, so every cut has
/// stretches that sit wholly on either side of it.
const STEP_SECONDS: f64 = 2.0;

/// A correlation peak below this is noise for this envelope at this length.
const PEAK_FLOOR: f32 = 0.5;

/// How many peaks of each stretch are followed. A repeated chorus produces a
/// peak per repeat, and the true one has to be among them.
const PEAKS_PER_WINDOW: usize = 4;

/// Two neighbouring stretches whose best lags differ by no more than this
/// many frames are the same alignment, drifting.
const LINK_FRAMES: f64 = 4.0;

/// How many distinct alignments the path may choose between.
const MAX_LINES: usize = 16;

/// A stretch correlating at this or better is the same music in both. Real
/// matches measured 0.75–1.0; a live take or a different recording of the
/// song peaks at random lags around 0.5–0.7 and never holds one.
const MATCH: f64 = 0.6;

/// What the path pays to change alignment. A repeated chorus can correlate a
/// hair better at the wrong repeat; that never pays for two changes.
const SWITCH_COST: f64 = 1.2;

/// Below this a stretch has no counterpart under an alignment: the edit
/// dropped it.
const GAP_CORRELATION: f64 = 0.45;

/// The furthest a recording is believed to run off speed. A vinyl rip or a
/// PAL transfer sits well inside it; beyond it a slope is a fitting error.
const MAX_RATE_DEVIATION: f64 = 0.01;

/// Fewer stretches than this in one alignment is a coincidence, not a section.
const MIN_SEGMENT_WINDOWS: usize = 3;

/// A rate is only fitted across at least this many matching stretches.
const MIN_RATE_WINDOWS: usize = 8;

/// The share of the shorter recording that must find its counterpart before
/// the map is trusted at all. A wrong map is worse than none. Measured on real
/// pairs: true matches cover 0.68–1.0 even when the video talks over its
/// second half; a live take covered 0.36, a different recording 0.09.
const MIN_COVERAGE: f64 = 0.6;

fn frames_per_second() -> f64 {
    SAMPLE_RATE as f64 / HOP as f64
}

pub struct Alignment {
    pub map: TimeMap,
    /// Mean correlation of the chosen alignment across the local file,
    /// stretches the video talks over included.
    pub confidence: f64,
}

/// Works out how the video's timeline maps onto the library file, section by
/// section, by matching the two recordings' onset envelopes. Returns `None`
/// unless most of the shorter recording finds its counterpart — a wrong
/// offset is worse than the zero the caller falls back to.
///
/// `local` is a path or a URL ffmpeg can read.
pub fn estimate(local: &str, video_audio: &str) -> Option<Alignment> {
    let local_samples = decode_mono(local)?;
    let video_samples = decode_mono(video_audio)?;
    let local_envelope = onset_envelope(&local_samples);
    let video_envelope = onset_envelope(&video_samples);
    map_envelopes(&local_envelope, &video_envelope)
}

/// Decodes any container ffmpeg understands down to mono f32 at the analysis
/// rate, capped at the analysis window.
fn decode_mono(source: &str) -> Option<Vec<f32>> {
    let ffmpeg = crate::downloads::resolve_tool("ffmpeg")?;
    let output = Command::new(ffmpeg)
        .args(["-v", "error", "-nostdin"])
        .arg("-i")
        .arg(source)
        .args(["-t", &MAX_ANALYSIS_SECONDS.to_string()])
        .args(["-ac", "1", "-ar", &SAMPLE_RATE.to_string()])
        .args(["-f", "f32le", "-"])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    if !output.status.success() || output.stdout.len() < FRAME * 4 {
        return None;
    }
    Some(
        output
            .stdout
            .chunks_exact(4)
            .map(|bytes| f32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]))
            .collect(),
    )
}

/// Spectral flux: per frame, the total rise in magnitude across the spectrum.
/// It peaks on note and drum onsets and is blind to level, EQ and mastering,
/// which is exactly the difference between an album master and a video's
/// soundtrack.
pub fn onset_envelope(samples: &[f32]) -> Vec<f64> {
    if samples.len() < FRAME {
        return Vec::new();
    }
    let window = hann(FRAME);
    let bins = FRAME / 2;
    let mut previous = vec![0.0f64; bins];
    let mut envelope = Vec::with_capacity((samples.len() - FRAME) / HOP + 1);
    let mut real = vec![0.0f64; FRAME];
    let mut imag = vec![0.0f64; FRAME];

    let mut start = 0;
    while start + FRAME <= samples.len() {
        for index in 0..FRAME {
            real[index] = samples[start + index] as f64 * window[index];
            imag[index] = 0.0;
        }
        fft(&mut real, &mut imag);
        let mut flux = 0.0;
        for bin in 0..bins {
            let magnitude = (real[bin] * real[bin] + imag[bin] * imag[bin]).sqrt();
            let rise = magnitude - previous[bin];
            if rise > 0.0 {
                flux += rise;
            }
            previous[bin] = magnitude;
        }
        envelope.push(flux);
        start += HOP;
    }
    if !envelope.is_empty() {
        envelope[0] = 0.0;
    }
    sharpen(&envelope)
}

/// Standard onset post-processing: subtract a local average and keep only what
/// rises above it. This strips the slow loudness contour — the part two
/// masters of the same song disagree about most — and leaves the attacks,
/// which they agree on.
fn sharpen(envelope: &[f64]) -> Vec<f64> {
    let window = (0.5 * frames_per_second()) as usize;
    if envelope.len() <= window || window == 0 {
        return envelope.to_vec();
    }
    let mut prefix = Vec::with_capacity(envelope.len() + 1);
    prefix.push(0.0);
    for value in envelope {
        prefix.push(prefix.last().copied().unwrap_or(0.0) + value);
    }
    envelope
        .iter()
        .enumerate()
        .map(|(index, value)| {
            let start = index.saturating_sub(window);
            let end = (index + window + 1).min(envelope.len());
            let local = (prefix[end] - prefix[start]) / (end - start) as f64;
            (value - local).max(0.0)
        })
        .collect()
}

/// The correlation of every stretch of the local envelope against every
/// position in the video's, normalised so 1.0 is identical shape.
struct Grid {
    window: usize,
    step: usize,
    starts: Vec<usize>,
    rows: Vec<Option<Vec<f32>>>,
}

impl Grid {
    fn build(local: &[f64], video: &[f64]) -> Option<Self> {
        let fps = frames_per_second();
        let window = (WINDOW_SECONDS * fps) as usize;
        let step = (STEP_SECONDS * fps) as usize;
        if local.len() < window || video.len() < window {
            return None;
        }
        let video32: Vec<f32> = video.iter().map(|value| *value as f32).collect();
        let deviations = sliding_deviation(video, window);
        let starts: Vec<usize> = (0..=local.len() - window).step_by(step).collect();
        let rows = starts
            .iter()
            .map(|start| correlate_window(&local[*start..*start + window], &video32, &deviations))
            .collect();
        Some(Self {
            window,
            step,
            starts,
            rows,
        })
    }

    fn centre(&self, index: usize) -> f64 {
        (self.starts[index] + self.window / 2) as f64
    }

    /// The correlation of stretch `index` when its centre lands `lag` frames
    /// later in the video, forgiving a frame either way of rounding.
    fn at(&self, index: usize, lag: f64) -> f64 {
        let Some(row) = &self.rows[index] else {
            return 0.0;
        };
        let position = (self.starts[index] as f64 + lag).round();
        if position < -1.0 || position > row.len() as f64 {
            return 0.0;
        }
        let centre = position as isize;
        (centre - 1..=centre + 1)
            .filter(|t| *t >= 0 && (*t as usize) < row.len())
            .map(|t| row[t as usize] as f64)
            .fold(0.0, f64::max)
    }

    /// The best lag near `lag`, to a fraction of a frame.
    fn refine(&self, index: usize, lag: f64) -> Option<(f64, f64)> {
        let row = self.rows[index].as_ref()?;
        let guess = (self.starts[index] as f64 + lag).round() as isize;
        let (best, value) = (guess - 3..=guess + 3)
            .filter(|t| *t >= 0 && (*t as usize) < row.len())
            .map(|t| (t as usize, row[t as usize]))
            .max_by(|a, b| a.1.total_cmp(&b.1))?;
        let shift = if best > 0 && best + 1 < row.len() {
            parabolic_peak(row[best - 1], row[best], row[best + 1])
        } else {
            0.0
        };
        Some((
            best as f64 + shift - self.starts[index] as f64,
            value as f64,
        ))
    }
}

/// Standard deviation of every `window`-long run of `values`.
fn sliding_deviation(values: &[f64], window: usize) -> Vec<f32> {
    let mut sum = vec![0.0f64; values.len() + 1];
    let mut squares = vec![0.0f64; values.len() + 1];
    for (index, value) in values.iter().enumerate() {
        sum[index + 1] = sum[index] + value;
        squares[index + 1] = squares[index] + value * value;
    }
    let size = window as f64;
    (0..=values.len() - window)
        .map(|start| {
            let mean = (sum[start + window] - sum[start]) / size;
            let variance = (squares[start + window] - squares[start]) / size - mean * mean;
            variance.max(0.0).sqrt() as f32
        })
        .collect()
}

/// Pearson correlation of one stretch against every position in the video.
/// The stretch is standardised once, so each position costs one dot product.
fn correlate_window(stretch: &[f64], video: &[f32], deviations: &[f32]) -> Option<Vec<f32>> {
    let standard = standardize(stretch)?;
    let standard: Vec<f32> = standard.iter().map(|value| *value as f32).collect();
    let size = standard.len() as f32;
    Some(
        deviations
            .iter()
            .enumerate()
            .map(|(start, deviation)| {
                if *deviation <= f32::EPSILON {
                    return 0.0;
                }
                dot(&standard, &video[start..start + standard.len()]) / (size * deviation)
            })
            .collect(),
    )
}

/// A dot product laid out so the compiler vectorises it: this loop is nearly
/// all of the aligner's time.
fn dot(left: &[f32], right: &[f32]) -> f32 {
    let mut lanes = [0.0f32; 8];
    let left_chunks = left.chunks_exact(8);
    let right_chunks = right.chunks_exact(8);
    let tail: f32 = left_chunks
        .remainder()
        .iter()
        .zip(right_chunks.remainder())
        .map(|(a, b)| a * b)
        .sum();
    for (a, b) in left_chunks.zip(right_chunks) {
        for lane in 0..8 {
            lanes[lane] += a[lane] * b[lane];
        }
    }
    lanes.iter().sum::<f32>() + tail
}

/// Mean-removed, unit-variance values, or `None` for a flat run (silence),
/// which matches everything and so nothing.
fn standardize(values: &[f64]) -> Option<Vec<f64>> {
    let mean = values.iter().sum::<f64>() / values.len() as f64;
    let variance = values
        .iter()
        .map(|value| (value - mean) * (value - mean))
        .sum::<f64>()
        / values.len() as f64;
    let deviation = variance.sqrt();
    if deviation <= 1e-9 {
        return None;
    }
    Some(
        values
            .iter()
            .map(|value| (value - mean) / deviation)
            .collect(),
    )
}

/// Where the true peak sits between three samples, as a shift from the middle
/// one in (-0.5, 0.5).
fn parabolic_peak(before: f32, peak: f32, after: f32) -> f64 {
    let curvature = before as f64 - 2.0 * peak as f64 + after as f64;
    if curvature.abs() <= f64::EPSILON {
        return 0.0;
    }
    (0.5 * (before as f64 - after as f64) / curvature).clamp(-0.5, 0.5)
}

/// One candidate alignment: the video frame for local frame `x` is
/// `x + lag + slope * x`.
#[derive(Clone, Copy, Debug)]
struct Line {
    lag: f64,
    slope: f64,
    support: f64,
}

impl Line {
    fn lag_at(&self, frame: f64) -> f64 {
        self.lag + self.slope * frame
    }
}

/// The strongest few local maxima of a row, at least half a second apart.
fn peaks(row: &[f32]) -> Vec<usize> {
    let separation = (0.5 * frames_per_second()) as usize;
    let mut found: Vec<usize> = Vec::new();
    let mut order: Vec<usize> = (0..row.len()).filter(|t| row[*t] >= PEAK_FLOOR).collect();
    order.sort_by(|a, b| row[*b].total_cmp(&row[*a]));
    for candidate in order {
        if found.len() == PEAKS_PER_WINDOW {
            break;
        }
        if found
            .iter()
            .all(|kept| kept.abs_diff(candidate) > separation)
        {
            found.push(candidate);
        }
    }
    found
}

/// Follows each stretch's peaks into its neighbours', so an alignment that
/// holds for a section — drifting slowly or not at all — becomes one line.
fn lines(grid: &Grid) -> Vec<Line> {
    struct Track {
        points: Vec<(usize, f64, f64)>,
    }
    let mut active: Vec<Track> = Vec::new();
    let mut finished: Vec<Track> = Vec::new();
    for index in 0..grid.starts.len() {
        let Some(row) = &grid.rows[index] else {
            continue;
        };
        for peak in peaks(row) {
            let lag = peak as f64 - grid.starts[index] as f64;
            let correlation = row[peak] as f64;
            let joined = active.iter_mut().find(|track| {
                let (last_index, last_lag, _) =
                    *track.points.last().expect("tracks start with a point");
                last_index != index
                    && index - last_index <= 2
                    && (last_lag - lag).abs() <= LINK_FRAMES
            });
            match joined {
                Some(track) => track.points.push((index, lag, correlation)),
                None => active.push(Track {
                    points: vec![(index, lag, correlation)],
                }),
            }
        }
        let (still, done): (Vec<Track>, Vec<Track>) = active.into_iter().partition(|track| {
            index - track.points.last().expect("tracks start with a point").0 <= 2
        });
        active = still;
        finished.extend(done);
    }
    finished.extend(active);

    let mut found: Vec<Line> = finished
        .into_iter()
        .filter(|track| track.points.len() >= MIN_SEGMENT_WINDOWS)
        .map(|track| {
            let points: Vec<(f64, f64, f64)> = track
                .points
                .iter()
                .map(|(index, lag, correlation)| (grid.centre(*index), *lag, *correlation))
                .collect();
            let span = track.points.last().map(|p| p.0).unwrap_or(0)
                - track.points.first().map(|p| p.0).unwrap_or(0);
            let (lag, slope) = fit(&points, span >= MIN_RATE_WINDOWS);
            Line {
                lag,
                slope,
                support: points.iter().map(|point| point.2).sum(),
            }
        })
        .collect();
    found.sort_by(|a, b| b.support.total_cmp(&a.support));
    found.truncate(MAX_LINES);
    found
}

/// Weighted least squares of lag against local frame. Without enough span to
/// trust a slope, the line is flat at the weighted mean lag.
fn fit(points: &[(f64, f64, f64)], with_slope: bool) -> (f64, f64) {
    let weight: f64 = points.iter().map(|p| p.2).sum();
    if weight <= f64::EPSILON {
        return (0.0, 0.0);
    }
    let mean_x = points.iter().map(|p| p.0 * p.2).sum::<f64>() / weight;
    let mean_y = points.iter().map(|p| p.1 * p.2).sum::<f64>() / weight;
    if !with_slope || points.len() < MIN_RATE_WINDOWS {
        return (mean_y, 0.0);
    }
    let spread: f64 = points.iter().map(|p| p.2 * (p.0 - mean_x).powi(2)).sum();
    if spread <= f64::EPSILON {
        return (mean_y, 0.0);
    }
    let slope = (points
        .iter()
        .map(|p| p.2 * (p.0 - mean_x) * (p.1 - mean_y))
        .sum::<f64>()
        / spread)
        .clamp(-MAX_RATE_DEVIATION, MAX_RATE_DEVIATION);
    (mean_y - slope * mean_x, slope)
}

/// Chooses one line per stretch, Viterbi-style: matching earns, changing line
/// costs, and the video may only run backwards across a stretch the earlier
/// line could not find — the one way a cut can make a lag fall. A wrong chorus
/// repeat would need the video to rewind mid-song, so it never qualifies.
fn choose_path(grid: &Grid, lines: &[Line], emissions: &[Vec<f64>]) -> Vec<usize> {
    let count = grid.starts.len();
    let width = lines.len();
    let mut gap = vec![vec![0usize; width]; count];
    for line in 0..width {
        let mut run = 0;
        for index in 0..count {
            gap[index][line] = run;
            run = if emissions[index][line] < GAP_CORRELATION {
                run + 1
            } else {
                0
            };
        }
    }

    let slack = grid.window as f64 + frames_per_second();
    let mut score: Vec<f64> = emissions[0].iter().map(|e| e - MATCH).collect();
    let mut back = vec![vec![0usize; width]; count];
    for index in 1..count {
        let centre = grid.centre(index);
        let mut next = vec![f64::NEG_INFINITY; width];
        for to in 0..width {
            let mut best = (score[to], to);
            if emissions[index][to] >= MATCH {
                let lag_to = lines[to].lag_at(centre);
                for from in (0..width).filter(|from| *from != to) {
                    let allowed = gap[index][from] as f64 * grid.step as f64 + slack;
                    if lag_to - lines[from].lag_at(centre) < -allowed {
                        continue;
                    }
                    let candidate = score[from] - SWITCH_COST;
                    if candidate > best.0 {
                        best = (candidate, from);
                    }
                }
            }
            next[to] = best.0 + emissions[index][to] - MATCH;
            back[index][to] = best.1;
        }
        score = next;
    }

    let mut line = (0..width)
        .max_by(|a, b| score[*a].total_cmp(&score[*b]))
        .unwrap_or(0);
    let mut path = vec![0usize; count];
    for index in (0..count).rev() {
        path[index] = line;
        line = back[index][line];
    }
    path
}

/// A run of stretches that kept one line.
struct Run {
    line: usize,
    first: usize,
    last: usize,
}

/// Collapses the path into runs and drops the ones too short or too weak to be
/// a section; their stretches fall to the run before, so the video plays on
/// through them instead of jumping twice.
fn sections(path: &[usize], emissions: &[Vec<f64>]) -> Vec<Run> {
    let mut runs: Vec<Run> = Vec::new();
    for (index, line) in path.iter().enumerate() {
        match runs.last_mut() {
            Some(run) if run.line == *line => run.last = index,
            _ => runs.push(Run {
                line: *line,
                first: index,
                last: index,
            }),
        }
    }
    let mut kept: Vec<Run> = runs
        .into_iter()
        .filter(|run| {
            let length = run.last - run.first + 1;
            let mean = (run.first..=run.last)
                .map(|index| emissions[index][run.line])
                .sum::<f64>()
                / length as f64;
            length >= MIN_SEGMENT_WINDOWS && mean >= MATCH
        })
        .collect();
    let mut merged: Vec<Run> = Vec::new();
    for run in kept.drain(..) {
        match merged.last_mut() {
            Some(previous) if previous.line == run.line => previous.last = run.last,
            _ => merged.push(run),
        }
    }
    if let Some(first) = merged.first_mut() {
        first.first = 0;
    }
    for index in 1..merged.len() {
        merged[index - 1].last = merged[index].first - 1;
    }
    if let Some(last) = merged.last_mut() {
        last.last = path.len() - 1;
    }
    merged
}

/// Fits a section's own lag and drift from the stretches that matched under
/// its line, each refined to a fraction of a frame.
fn fit_section(grid: &Grid, line: &Line, run: &Run) -> Line {
    let points: Vec<(f64, f64, f64)> =
        (run.first..=run.last)
            .filter_map(|index| {
                let centre = grid.centre(index);
                let (lag, correlation) = grid.refine(index, line.lag_at(centre))?;
                (correlation >= MATCH && (lag - line.lag_at(centre)).abs() <= LINK_FRAMES)
                    .then_some((centre, lag, correlation))
            })
            .collect();
    if points.is_empty() {
        return *line;
    }
    let (lag, slope) = fit(&points, true);
    Line {
        lag,
        slope,
        support: line.support,
    }
}

/// Finds the exact local frame where the video switches from `before` to
/// `after`, by scoring every candidate frame around the first stretch of the
/// later section: onsets before it should agree under `before`, onsets after
/// it under `after`.
fn switch_frame(
    local: &[f64],
    video: &[f64],
    before: &Line,
    after: &Line,
    around: usize,
    window: usize,
) -> usize {
    let low = around.saturating_sub(window);
    let high = (around + window).min(local.len());
    if high <= low {
        return around;
    }
    let agreement = |line: &Line, frame: usize| -> f64 {
        let position = (frame as f64 + line.lag_at(frame as f64)).round();
        if position < 0.0 || position as usize >= video.len() {
            return 0.0;
        }
        local[frame] * video[position as usize]
    };
    let mut total_after: f64 = (low..high).map(|frame| agreement(after, frame)).sum();
    let mut total_before = 0.0;
    let mut best = (total_after, low);
    for frame in low..high {
        total_before += agreement(before, frame);
        total_after -= agreement(after, frame);
        if total_before + total_after > best.0 {
            best = (total_before + total_after, frame + 1);
        }
    }
    best.1
}

/// The pure half of `estimate`, on onset envelopes at the analysis frame
/// rate: one segment per section of the video's edit.
pub fn map_envelopes(local: &[f64], video: &[f64]) -> Option<Alignment> {
    let grid = Grid::build(local, video)?;
    if grid.starts.len() < MIN_SEGMENT_WINDOWS {
        return None;
    }
    let candidates = lines(&grid);
    if candidates.is_empty() {
        return None;
    }
    let emissions: Vec<Vec<f64>> = (0..grid.starts.len())
        .map(|index| {
            let centre = grid.centre(index);
            candidates
                .iter()
                .map(|line| grid.at(index, line.lag_at(centre)))
                .collect()
        })
        .collect();
    let path = choose_path(&grid, &candidates, &emissions);
    let runs = sections(&path, &emissions);
    if runs.is_empty() {
        return None;
    }

    let audible: Vec<usize> = (0..grid.starts.len())
        .filter(|index| grid.rows[*index].is_some())
        .collect();
    let line_of = |index: usize| {
        runs.iter()
            .find(|run| (run.first..=run.last).contains(&index))
            .map(|run| run.line)
            .unwrap_or(0)
    };
    let matched = audible
        .iter()
        .filter(|index| emissions[**index][line_of(**index)] >= MATCH)
        .count();
    let video_windows = (video.len().saturating_sub(grid.window)) / grid.step + 1;
    let coverage = matched as f64 / audible.len().min(video_windows).max(1) as f64;
    let confidence = audible
        .iter()
        .map(|index| emissions[*index][line_of(*index)])
        .sum::<f64>()
        / audible.len().max(1) as f64;
    if coverage < MIN_COVERAGE {
        return None;
    }

    let fitted: Vec<Line> = runs
        .iter()
        .map(|run| fit_section(&grid, &candidates[run.line], run))
        .collect();
    let standard_local = standardize(local)?;
    let standard_video = standardize(video)?;
    let fps = frames_per_second();
    let mut segments = Vec::with_capacity(runs.len());
    for (index, (run, line)) in runs.iter().zip(&fitted).enumerate() {
        let start = if index == 0 {
            0
        } else {
            switch_frame(
                &standard_local,
                &standard_video,
                &fitted[index - 1],
                line,
                grid.starts[run.first] + grid.window / 2,
                grid.window,
            )
        };
        let frame = start as f64;
        segments.push(Segment {
            start: frame / fps,
            offset: line.lag_at(frame) / fps,
            rate: 1.0 + line.slope,
        });
    }
    Some(Alignment {
        map: TimeMap::new(segments),
        confidence: confidence.clamp(0.0, 1.0),
    })
}

fn hann(size: usize) -> Vec<f64> {
    (0..size)
        .map(|index| {
            let phase = std::f64::consts::TAU * index as f64 / size as f64;
            0.5 - 0.5 * phase.cos()
        })
        .collect()
}

/// In-place iterative radix-2 FFT. `real` and `imag` must be the same
/// power-of-two length.
pub fn fft(real: &mut [f64], imag: &mut [f64]) {
    let n = real.len();
    debug_assert!(n.is_power_of_two());
    debug_assert_eq!(n, imag.len());

    let mut target = 0usize;
    for source in 1..n {
        let mut bit = n >> 1;
        while target & bit != 0 {
            target ^= bit;
            bit >>= 1;
        }
        target |= bit;
        if source < target {
            real.swap(source, target);
            imag.swap(source, target);
        }
    }

    let mut span = 2;
    while span <= n {
        let step = -std::f64::consts::TAU / span as f64;
        let half = span / 2;
        for block in (0..n).step_by(span) {
            for offset in 0..half {
                let angle = step * offset as f64;
                let (sin, cos) = angle.sin_cos();
                let index = block + offset;
                let partner = index + half;
                let real_part = real[partner] * cos - imag[partner] * sin;
                let imag_part = real[partner] * sin + imag[partner] * cos;
                real[partner] = real[index] - real_part;
                imag[partner] = imag[index] - imag_part;
                real[index] += real_part;
                imag[index] += imag_part;
            }
        }
        span <<= 1;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn naive_dft(input: &[f64]) -> Vec<(f64, f64)> {
        let n = input.len();
        (0..n)
            .map(|bin| {
                let mut real = 0.0;
                let mut imag = 0.0;
                for (index, value) in input.iter().enumerate() {
                    let angle = -std::f64::consts::TAU * bin as f64 * index as f64 / n as f64;
                    real += value * angle.cos();
                    imag += value * angle.sin();
                }
                (real, imag)
            })
            .collect()
    }

    #[test]
    fn fft_matches_a_naive_transform() {
        let input: Vec<f64> = (0..64)
            .map(|index| (index as f64 * 0.37).sin() + 0.3 * (index as f64 * 1.9).cos())
            .collect();
        let expected = naive_dft(&input);
        let mut real = input.clone();
        let mut imag = vec![0.0; input.len()];
        fft(&mut real, &mut imag);
        for bin in 0..input.len() {
            assert!((real[bin] - expected[bin].0).abs() < 1e-9, "bin {bin} real");
            assert!((imag[bin] - expected[bin].1).abs() < 1e-9, "bin {bin} imag");
        }
    }

    /// Renders a short passage of "music": note attacks at irregular intervals
    /// with varying pitch and loudness, so the pattern never repeats and a
    /// correlation has one true answer. `gain` and `bright` stand in for a
    /// different master of the same recording.
    fn render(seconds: f64, seed: u64, gain: f32, bright: f32) -> Vec<f32> {
        let total = (seconds * SAMPLE_RATE as f64) as usize;
        let mut samples = vec![0.0f32; total];
        let mut state = seed;
        let mut next = |modulo: u64| {
            state = state
                .wrapping_mul(6364136223846793005)
                .wrapping_add(1442695040888963407);
            (state >> 33) % modulo
        };
        let mut at = 0.0f64;
        while at < seconds {
            let pitch = 110.0 * (1 + next(12)) as f64 / 4.0;
            let level = 0.25 + next(100) as f64 / 200.0;
            let decay = 6.0 + next(40) as f64 / 10.0;
            let start = (at * SAMPLE_RATE as f64) as usize;
            for offset in 0..(SAMPLE_RATE / 3) {
                let index = start + offset;
                if index >= total {
                    break;
                }
                let time = offset as f64 / SAMPLE_RATE as f64;
                let envelope = (-decay * time).exp() * level;
                let phase = std::f64::consts::TAU * pitch * time;
                let tone = phase.sin() + bright as f64 * (phase * 2.0).sin();
                samples[index] += (envelope * tone) as f32 * gain;
            }
            at += 0.17 + next(45) as f64 / 100.0;
        }
        samples
    }

    fn seconds(value: f64) -> usize {
        (value * SAMPLE_RATE as f64) as usize
    }

    fn only_segment(alignment: &Alignment) -> Segment {
        assert_eq!(
            alignment.map.segments().len(),
            1,
            "expected one section, got {:?}",
            alignment.map.segments()
        );
        alignment.map.segments()[0]
    }

    #[test]
    fn recovers_a_video_that_starts_late() {
        let master = render(110.0, 7, 1.0, 0.15);
        let video = render(110.0, 7, 0.6, 0.45);
        let local = onset_envelope(&master[seconds(12.0)..]);
        let alignment =
            map_envelopes(&local, &onset_envelope(&video)).expect("the same passage must align");
        let segment = only_segment(&alignment);
        assert!(
            (segment.offset - 12.0).abs() < 0.05,
            "offset was {}",
            segment.offset
        );
        assert!((segment.rate - 1.0).abs() < 0.001);
        assert!(alignment.confidence > MATCH);
    }

    #[test]
    fn recovers_a_video_that_starts_early() {
        let master = render(110.0, 21, 1.0, 0.2);
        let video = render(110.0, 21, 1.4, 0.05);
        let local = onset_envelope(&master);
        let video = onset_envelope(&video[seconds(9.0)..]);
        let alignment = map_envelopes(&local, &video).expect("the same passage must align");
        let segment = only_segment(&alignment);
        assert!(
            (segment.offset + 9.0).abs() < 0.05,
            "offset was {}",
            segment.offset
        );
    }

    #[test]
    fn a_head_start_longer_than_a_minute_is_still_found() {
        let master = render(150.0, 33, 1.0, 0.2);
        let local = onset_envelope(&master[seconds(80.0)..]);
        let video = onset_envelope(&render(150.0, 33, 0.8, 0.3));
        let alignment = map_envelopes(&local, &video).expect("an 80 s intro must still align");
        assert!((only_segment(&alignment).offset - 80.0).abs() < 0.05);
    }

    #[test]
    fn a_verse_the_edit_dropped_becomes_a_cut() {
        let master = render(120.0, 11, 1.0, 0.2);
        let mut edit = master[..seconds(45.0)].to_vec();
        edit.extend_from_slice(&master[seconds(65.0)..]);
        let alignment = map_envelopes(&onset_envelope(&master), &onset_envelope(&edit))
            .expect("an edit of the same recording must align");
        let segments = alignment.map.segments();
        assert_eq!(segments.len(), 2, "{segments:?}");
        assert!(segments[0].offset.abs() < 0.05);
        assert!((segments[1].offset + 20.0).abs() < 0.05, "{segments:?}");
        assert!(
            (45.0..=66.0).contains(&segments[1].start),
            "the cut belongs between 45 s and 65 s: {segments:?}"
        );
        assert!((alignment.map.video_time(90.0) - 70.0).abs() < 0.05);
    }

    #[test]
    fn a_scene_the_video_inserted_is_skipped() {
        let master = render(110.0, 5, 1.0, 0.2);
        let scene = render(15.0, 424_242, 1.0, 0.6);
        let mut video = master[..seconds(50.0)].to_vec();
        video.extend_from_slice(&scene);
        video.extend_from_slice(&master[seconds(50.0)..]);
        let alignment = map_envelopes(&onset_envelope(&master), &onset_envelope(&video))
            .expect("the music around the scene must align");
        let segments = alignment.map.segments();
        assert_eq!(segments.len(), 2, "{segments:?}");
        assert!(segments[0].offset.abs() < 0.05);
        assert!((segments[1].offset - 15.0).abs() < 0.05, "{segments:?}");
        assert!(
            (segments[1].start - 50.0).abs() < 1.0,
            "the scene starts at 50 s: {segments:?}"
        );
    }

    #[test]
    fn a_repeated_chorus_does_not_pull_the_video_to_the_wrong_repeat() {
        let verse_one = render(30.0, 101, 1.0, 0.2);
        let chorus = render(16.0, 202, 1.0, 0.2);
        let verse_two = render(30.0, 303, 1.0, 0.2);
        let outro = render(20.0, 404, 1.0, 0.2);
        let mut song = verse_one.clone();
        song.extend_from_slice(&chorus);
        song.extend_from_slice(&verse_two);
        song.extend_from_slice(&chorus);
        song.extend_from_slice(&outro);
        let mut video = render(6.0, 505, 1.0, 0.2);
        video.extend_from_slice(&song);
        let alignment = map_envelopes(&onset_envelope(&song), &onset_envelope(&video))
            .expect("the song must align");
        let segment = only_segment(&alignment);
        assert!(
            (segment.offset - 6.0).abs() < 0.05,
            "offset was {}",
            segment.offset
        );
    }

    #[test]
    fn a_rip_running_off_speed_is_followed_by_its_rate() {
        let master = render(120.0, 17, 1.0, 0.2);
        let speed = 1.004;
        let length = (master.len() as f64 / speed) as usize;
        let slowed: Vec<f32> = (0..length)
            .map(|index| {
                let position = index as f64 * speed;
                let base = position.floor() as usize;
                let fraction = (position - base as f64) as f32;
                let next = master.get(base + 1).copied().unwrap_or(0.0);
                master[base] * (1.0 - fraction) + next * fraction
            })
            .collect();
        let alignment = map_envelopes(&onset_envelope(&slowed), &onset_envelope(&master))
            .expect("an off-speed copy must align");
        let segment = only_segment(&alignment);
        assert!(
            (segment.rate - speed).abs() < 0.0005,
            "rate was {}",
            segment.rate
        );
        assert!((alignment.map.video_time(100.0) - 100.0 * speed).abs() < 0.08);
    }

    #[test]
    fn two_unrelated_recordings_produce_no_alignment() {
        let local = onset_envelope(&render(110.0, 3, 1.0, 0.2));
        let video = onset_envelope(&render(110.0, 999_331, 1.0, 0.2));
        assert!(map_envelopes(&local, &video).is_none());
    }

    #[test]
    fn too_little_audio_produces_no_alignment() {
        let short = onset_envelope(&render(9.0, 5, 1.0, 0.2));
        assert!(map_envelopes(&short, &short).is_none());
    }

    #[test]
    fn silence_produces_no_alignment() {
        let silence = vec![0.0; 6000];
        assert!(map_envelopes(&silence, &silence).is_none());
    }

    #[test]
    fn an_envelope_reacts_to_onsets_not_to_steady_tone() {
        let steady: Vec<f32> = (0..SAMPLE_RATE * 2)
            .map(|index| (index as f32 * 0.05).sin() * 0.5)
            .collect();
        let mut bursty = vec![0.0f32; SAMPLE_RATE * 2];
        for (index, sample) in bursty.iter_mut().enumerate() {
            if index % (SAMPLE_RATE / 2) < 400 {
                *sample = (index as f32 * 0.4).sin();
            }
        }
        let steady_envelope = onset_envelope(&steady);
        let bursty_envelope = onset_envelope(&bursty);
        let peak = |values: &[f64]| values.iter().cloned().fold(0.0f64, f64::max);
        let mean = |values: &[f64]| values.iter().sum::<f64>() / values.len() as f64;
        assert!(peak(&bursty_envelope) / mean(&bursty_envelope).max(1e-9) > 5.0);
        assert!(
            peak(&steady_envelope) / mean(&steady_envelope).max(1e-9)
                < peak(&bursty_envelope) / mean(&bursty_envelope).max(1e-9)
        );
    }

    /// Runs the aligner over real library songs and their videos' soundtracks,
    /// listed one `local-path<TAB>video-audio-path` per line in the file named
    /// by `FLACCY_ALIGN_PAIRS`.
    #[test]
    #[ignore]
    fn real_pairs() {
        let Ok(list) = std::env::var("FLACCY_ALIGN_PAIRS") else {
            return;
        };
        for line in std::fs::read_to_string(list).unwrap().lines() {
            let Some((local, video)) = line.split_once('\t') else {
                continue;
            };
            let started = std::time::Instant::now();
            let result = estimate(local, video);
            let name = std::path::Path::new(local)
                .file_name()
                .unwrap()
                .to_string_lossy();
            match result {
                Some(alignment) => println!(
                    "{name}: {} ({:.2}) in {:.2}s",
                    alignment.map.encode(),
                    alignment.confidence,
                    started.elapsed().as_secs_f64()
                ),
                None => println!("{name}: none in {:.2}s", started.elapsed().as_secs_f64()),
            }
        }
    }
}
