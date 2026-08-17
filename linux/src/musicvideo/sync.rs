/// Inside this the video is considered locked to the audio and left alone. A
/// frame at 24 fps lasts 42 ms, so nothing under a couple of frames is worth
/// chasing.
pub const LOCKED: f64 = 0.06;

/// Beyond this a rate nudge would take too long to close the gap and the
/// mismatch is already visible, so the video is seeked outright.
pub const HARD_SEEK: f64 = 0.75;

/// The furthest the video is ever run from real time. With no audio to
/// pitch-shift, eight percent is invisible; more starts to look like a stutter
/// on slow pans.
pub const MAX_RATE_DEVIATION: f64 = 0.08;

/// How long a rate nudge is aimed to take to close the gap it was given.
const CONVERGE_SECONDS: f64 = 5.0;

/// A flushing seek on a network stream costs a rebuffer, so consecutive seeks
/// are spaced out; between them the rate nudge does what it can.
const SEEK_COOLDOWN: f64 = 2.5;

/// Rate changes below this aren't worth an event on the pipeline.
const RATE_EPSILON: f64 = 0.004;

#[derive(Clone, Copy, PartialEq, Debug)]
pub enum Correction {
    /// Run the video at this rate relative to real time.
    Rate(f64),
    /// Jump the video to the audio's position, gap closed at once.
    Seek,
}

/// Keeps the video locked to the audio clock. Drift is measured as
/// `video_position - target`: positive means the picture has run ahead of the
/// sound.
pub struct Governor {
    rate: f64,
    last_seek_at: Option<f64>,
}

impl Default for Governor {
    fn default() -> Self {
        Self {
            rate: 1.0,
            last_seek_at: None,
        }
    }
}

impl Governor {
    /// Reports what to do about the current drift, or `None` when the pipeline
    /// is already doing it. `now` is any monotonic clock in seconds.
    pub fn step(&mut self, drift: f64, now: f64) -> Option<Correction> {
        if drift.abs() >= HARD_SEEK && self.seek_allowed(now) {
            self.last_seek_at = Some(now);
            self.rate = 1.0;
            return Some(Correction::Seek);
        }
        let wanted = if drift.abs() <= LOCKED {
            1.0
        } else {
            (1.0 - drift / CONVERGE_SECONDS)
                .clamp(1.0 - MAX_RATE_DEVIATION, 1.0 + MAX_RATE_DEVIATION)
        };
        if (wanted - self.rate).abs() < RATE_EPSILON {
            return None;
        }
        self.rate = wanted;
        Some(Correction::Rate(wanted))
    }

    /// Called after a seek the governor did not order — a track change, a user
    /// scrub, a stream reload — so the next step starts from a clean slate.
    pub fn reset(&mut self, now: f64) {
        self.rate = 1.0;
        self.last_seek_at = Some(now);
    }

    fn seek_allowed(&self, now: f64) -> bool {
        match self.last_seek_at {
            None => true,
            Some(previous) => now - previous >= SEEK_COOLDOWN,
        }
    }
}

/// Where the video should be for a given moment in the local audio. The offset
/// absorbs everything that makes a video's timeline differ from the album
/// master: title cards, spoken intros, a cold open.
pub fn target(audio_position: f64, offset: f64) -> f64 {
    (audio_position + offset).max(0.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_locked_video_is_left_alone() {
        let mut governor = Governor::default();
        assert_eq!(governor.step(0.02, 0.0), None);
        assert_eq!(governor.step(0.02, 0.5), None);
    }

    #[test]
    fn a_video_running_ahead_is_slowed_down() {
        let mut governor = Governor::default();
        let Some(Correction::Rate(rate)) = governor.step(0.3, 0.0) else {
            panic!("expected a rate nudge");
        };
        assert!(rate < 1.0 && rate > 1.0 - MAX_RATE_DEVIATION - 1e-9);
    }

    #[test]
    fn a_video_running_behind_is_sped_up() {
        let mut governor = Governor::default();
        let Some(Correction::Rate(rate)) = governor.step(-0.3, 0.0) else {
            panic!("expected a rate nudge");
        };
        assert!(rate > 1.0 && rate < 1.0 + MAX_RATE_DEVIATION + 1e-9);
    }

    #[test]
    fn the_rate_is_never_pushed_past_the_ceiling() {
        let mut governor = Governor::default();
        let Some(Correction::Rate(rate)) = governor.step(-0.7, 0.0) else {
            panic!("expected a rate nudge");
        };
        assert!((rate - (1.0 + MAX_RATE_DEVIATION)).abs() < 1e-9);
    }

    #[test]
    fn a_large_gap_is_seeked_not_nudged() {
        let mut governor = Governor::default();
        assert_eq!(governor.step(3.0, 0.0), Some(Correction::Seek));
        assert_eq!(governor.step(0.0, 0.1), None);
    }

    #[test]
    fn seeks_are_spaced_out_and_nudging_covers_the_gap_between() {
        let mut governor = Governor::default();
        assert_eq!(governor.step(3.0, 10.0), Some(Correction::Seek));
        let Some(Correction::Rate(rate)) = governor.step(3.0, 10.5) else {
            panic!("a second seek is on cooldown, so it must nudge instead");
        };
        assert!((rate - (1.0 - MAX_RATE_DEVIATION)).abs() < 1e-9);
        assert_eq!(governor.step(3.0, 13.0), Some(Correction::Seek));
    }

    #[test]
    fn returning_to_lock_restores_real_time_once() {
        let mut governor = Governor::default();
        assert!(matches!(governor.step(0.3, 0.0), Some(Correction::Rate(_))));
        assert_eq!(governor.step(0.0, 0.5), Some(Correction::Rate(1.0)));
        assert_eq!(governor.step(0.0, 1.0), None);
    }

    #[test]
    fn tiny_rate_changes_are_not_worth_an_event() {
        let mut governor = Governor::default();
        assert!(matches!(governor.step(0.30, 0.0), Some(Correction::Rate(_))));
        assert_eq!(governor.step(0.3005, 0.2), None);
    }

    #[test]
    fn a_reset_puts_the_pipeline_back_to_real_time_and_arms_the_cooldown() {
        let mut governor = Governor::default();
        assert!(matches!(governor.step(0.3, 0.0), Some(Correction::Rate(_))));
        governor.reset(1.0);
        assert_eq!(governor.step(0.0, 1.1), None);
        assert!(matches!(governor.step(3.0, 1.5), Some(Correction::Rate(_))));
    }

    #[test]
    fn a_repeated_nudge_converges_on_lock() {
        let mut governor = Governor::default();
        let mut drift = 0.5;
        let mut rate = 1.0;
        let mut now = 0.0;
        for _ in 0..80 {
            if let Some(Correction::Rate(nudged)) = governor.step(drift, now) {
                rate = nudged;
            }
            drift += (rate - 1.0) * 0.2;
            now += 0.2;
        }
        assert!(drift.abs() <= LOCKED, "converged to {drift}");
    }

    #[test]
    fn the_target_follows_the_offset_and_never_goes_negative() {
        assert_eq!(target(10.0, 12.5), 22.5);
        assert_eq!(target(10.0, -4.0), 6.0);
        assert_eq!(target(1.0, -9.0), 0.0);
    }
}
