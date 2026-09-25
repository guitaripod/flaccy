use crate::app::AppCore;
use gtk::glib;
use std::rc::Rc;
use std::time::Duration;

/// Gap between drag events, matching a pointer on a 165 Hz display — the rate
/// that used to wedge the audio stream within three drags.
const DRAG_INTERVAL: u64 = 6;
const DRAG_EVENTS: usize = 60;
const SWEEPS: usize = 8;
/// A key held down auto-repeats at roughly this rate.
const KEY_REPEAT_INTERVAL: u64 = 30;
const KEY_REPEATS: usize = 24;
/// How long the audio must keep moving after each round, and by how much.
const SETTLE: u64 = 700;
const LISTEN: u64 = 2000;
const MIN_ADVANCE: f64 = 1.2;
/// How long the drill holds the knob at the very end, long enough for the
/// track to drain and reach end-of-stream underneath the gesture.
const TAIL_DWELL: u64 = 1500;
/// Long enough, from four seconds before the end, for playbin3 to raise
/// `about-to-finish` and queue the next track.
const DRAIN_WAIT: u64 = 2600;
/// How long a reopened tail gets to hand off to the next track.
const HANDOFF_WAIT: u64 = 4000;

#[derive(Clone, Copy, Debug)]
enum Gesture {
    Hold,
    Drag(f64),
    Release(f64),
    Skip(f64),
    Seek(f64),
    Listen(&'static str),
    Handoff,
}

/// Demo-mode drill for the seek path (`FLACCY_DEMO_SCRUB_DRILL`), run against
/// the real audio sink: display-rate drags back and forth, a drag through the
/// drained tail of the track and back out, and a held skip key. After each
/// round it listens for two seconds and logs PASS if playback kept moving,
/// FAIL if it froze — which is what every flood of seeks used to end in. It
/// ends with a seek made after the next track was already queued, and checks
/// the reopened track still hands off to the next one.
pub fn run(core: &Rc<AppCore>) {
    let Some(track) = core.player.current_track() else {
        crate::logger::error("drill", "SCRUB DRILL: nothing is playing");
        return;
    };
    let script = script(track.duration);
    crate::logger::info(
        "drill",
        &format!(
            "SCRUB DRILL: {} steps against {} ({:.0}s)",
            script.len(),
            track.title,
            track.duration
        ),
    );
    step(Rc::clone(core), Rc::new(script), 0, Rc::new(Tally::default()));
}

#[derive(Default)]
struct Tally {
    passed: std::cell::Cell<usize>,
    failed: std::cell::Cell<usize>,
}

impl Tally {
    fn record(&self, passed: bool) {
        let counter = if passed { &self.passed } else { &self.failed };
        counter.set(counter.get() + 1);
    }
}

fn verdict(passed: bool) -> &'static str {
    if passed {
        "PASS"
    } else {
        "FAIL"
    }
}

fn script(duration: f64) -> Vec<(u64, Gesture)> {
    let mut script = Vec::new();
    let drag = |script: &mut Vec<(u64, Gesture)>, from: f64, to: f64| {
        for index in 0..DRAG_EVENTS {
            let fraction = from + (to - from) * index as f64 / (DRAG_EVENTS - 1) as f64;
            script.push((DRAG_INTERVAL, Gesture::Drag(duration * fraction)));
        }
    };
    for round in 0..SWEEPS {
        let (from, to) = if round % 2 == 0 {
            (0.15, 0.65)
        } else {
            (0.65, 0.15)
        };
        script.push((0, Gesture::Hold));
        drag(&mut script, from, to);
        script.push((DRAG_INTERVAL, Gesture::Release(duration * to)));
        script.push((SETTLE, Gesture::Listen("display-rate drag")));
    }
    script.push((0, Gesture::Hold));
    drag(&mut script, 0.5, 1.0);
    script.push((TAIL_DWELL, Gesture::Drag(duration)));
    drag(&mut script, 1.0, 0.3);
    script.push((DRAG_INTERVAL, Gesture::Release(duration * 0.3)));
    script.push((SETTLE, Gesture::Listen("a drag held past the end and back")));
    for _ in 0..KEY_REPEATS {
        script.push((KEY_REPEAT_INTERVAL, Gesture::Skip(-1.0)));
    }
    script.push((SETTLE, Gesture::Listen("a held skip key")));
    script.push((0, Gesture::Seek(duration - 4.0)));
    script.push((DRAIN_WAIT, Gesture::Seek(duration - 1.6)));
    script.push((0, Gesture::Handoff));
    script
}

fn step(core: Rc<AppCore>, script: Rc<Vec<(u64, Gesture)>>, index: usize, tally: Rc<Tally>) {
    let Some(&(delay, gesture)) = script.get(index) else {
        let (passed, failed) = (tally.passed.get(), tally.failed.get());
        let verdict = if failed == 0 { "PASSED" } else { "FAILED" };
        crate::logger::info(
            "drill",
            &format!("SCRUB DRILL {verdict}: {passed} checks passed, {failed} failed"),
        );
        return;
    };
    glib::timeout_add_local_once(Duration::from_millis(delay), move || {
        let player = &core.player;
        match gesture {
            Gesture::Hold => player.begin_scrub(),
            Gesture::Drag(seconds) => player.scrub_to(seconds),
            Gesture::Release(seconds) => player.finish_scrub(seconds),
            Gesture::Skip(seconds) => core.skip_by(seconds),
            Gesture::Seek(seconds) => player.seek(seconds),
            Gesture::Handoff => {
                let before = player.current_track().map(|track| track.rel_path);
                glib::timeout_add_local_once(Duration::from_millis(HANDOFF_WAIT), move || {
                    let after = core.player.current_track().map(|track| track.rel_path);
                    let passed = after.is_some() && after != before && core.player.is_playing();
                    tally.record(passed);
                    crate::logger::info(
                        "drill",
                        &format!(
                            "{} handing off to the next track after a seek in the drained tail",
                            verdict(passed)
                        ),
                    );
                    step(core, script, index + 1, tally);
                });
                return;
            }
            Gesture::Listen(what) => {
                let before = player.position().unwrap_or(0.0);
                glib::timeout_add_local_once(Duration::from_millis(LISTEN), move || {
                    let after = core.player.position().unwrap_or(0.0);
                    let moved = after - before;
                    let passed = moved >= MIN_ADVANCE && core.player.is_playing();
                    tally.record(passed);
                    crate::logger::info(
                        "drill",
                        &format!(
                            "{} after {what}: {before:.2}s -> {after:.2}s",
                            verdict(passed)
                        ),
                    );
                    step(core, script, index + 1, tally);
                });
                return;
            }
        }
        step(core, script, index + 1, tally);
    });
}
