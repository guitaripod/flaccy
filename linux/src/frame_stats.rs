use gtk::glib;
use gtk::prelude::*;
use std::cell::Cell;
use std::rc::Rc;
use std::time::Duration;

const ENV: &str = "FLACCY_FRAME_STATS";
const STALL_PROBE: Duration = Duration::from_millis(10);
const STALL_REPORTED_MS: i64 = 50;
const SLOW_HANDLER: Duration = Duration::from_millis(8);

/// Whether `FLACCY_FRAME_STATS` is set, read once.
pub fn enabled() -> bool {
    static ENABLED: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *ENABLED.get_or_init(|| std::env::var_os(ENV).is_some())
}

/// Logs an event-hub subscriber that held the main thread for at least
/// `SLOW_HANDLER`, named by the line that subscribed it.
pub fn note_handler(origin: &std::panic::Location<'static>, took: Duration) {
    if took >= SLOW_HANDLER {
        crate::logger::info(
            "frames",
            &format!(
                "handler {}:{} took {:.1}ms",
                origin.file(),
                origin.line(),
                took.as_secs_f64() * 1000.0
            ),
        );
    }
}

/// What the window's frame clock did over the last second, in microseconds of
/// main-thread time: the update phase (tick callbacks, CSS animations), the
/// layout phase, and the paint phase (snapshotting the widget tree and handing
/// it to the renderer). A phase a cycle skips is charged to the next one that
/// runs, so nothing is ever measured across cycles.
#[derive(Default)]
struct Tally {
    cycles: Cell<u32>,
    update: Cell<i64>,
    layout: Cell<i64>,
    paint: Cell<i64>,
    marker: Cell<i64>,
}

impl Tally {
    fn lap(&self, total: &Cell<i64>) {
        let now = glib::monotonic_time();
        total.set(total.get() + (now - self.marker.replace(now)).max(0));
    }

    fn report(&self) -> String {
        let cycles = self.cycles.replace(0);
        let (update, layout, paint) = (
            self.update.replace(0),
            self.layout.replace(0),
            self.paint.replace(0),
        );
        let busy_ms = (update + layout + paint) as f64 / 1000.0;
        format!(
            "cycles={cycles} busy={busy_ms:.1}ms update={:.1}ms layout={:.1}ms paint={:.1}ms",
            update as f64 / 1000.0,
            layout as f64 / 1000.0,
            paint as f64 / 1000.0,
        )
    }
}

/// Logs the frame clock's cycle count and where each cycle's main-thread time
/// went, once a second, when `FLACCY_FRAME_STATS=1`. A resting window logs
/// zero cycles; a window that logs a steady rate while nothing on screen is
/// moving has an animation or a tick callback that never lets the clock sleep,
/// and `paint` is what each of those cycles costs. Handlers are connected
/// after the toolkit's own, so each phase's time is read when its work is done.
pub fn install(window: &impl IsA<gtk::Widget>) {
    if !enabled() {
        return;
    }
    window.connect_realize(|window| {
        let Some(clock) = window.frame_clock() else {
            return;
        };
        let tally = Rc::new(Tally::default());
        {
            let tally = Rc::clone(&tally);
            clock.connect_before_paint(move |_| {
                tally.cycles.set(tally.cycles.get() + 1);
                tally.marker.set(glib::monotonic_time());
            });
        }
        {
            let tally = Rc::clone(&tally);
            clock.connect_update(move |_| tally.lap(&tally.update));
        }
        {
            let tally = Rc::clone(&tally);
            clock.connect_layout(move |_| tally.lap(&tally.layout));
        }
        {
            let tally = Rc::clone(&tally);
            clock.connect_paint(move |_| tally.lap(&tally.paint));
        }
        glib::timeout_add_local(Duration::from_secs(1), move || {
            crate::logger::info("frames", &tally.report());
            glib::ControlFlow::Continue
        });
        watch_for_stalls();
    });
}

/// Logs every stretch of at least `STALL_REPORTED_MS` in which the main loop
/// could not get back to a high-priority probe that wants to run every
/// `STALL_PROBE`: a click handler, a query or a decode that froze the window
/// for that long, whether or not a frame was due.
fn watch_for_stalls() {
    let expected = Cell::new(glib::monotonic_time());
    let period_us = STALL_PROBE.as_micros() as i64;
    glib::timeout_add_local_full(STALL_PROBE, glib::Priority::HIGH, move || {
        let now = glib::monotonic_time();
        let late_ms = (now - expected.get() - period_us) / 1000;
        if late_ms >= STALL_REPORTED_MS {
            crate::logger::info("frames", &format!("stall={late_ms}ms"));
        }
        expected.set(now);
        glib::ControlFlow::Continue
    });
}
