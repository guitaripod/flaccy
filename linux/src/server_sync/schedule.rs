use std::time::{Duration, Instant};

const FOCUSED_POLL: Duration = Duration::from_secs(30);
const BACKGROUND_POLL: Duration = Duration::from_secs(5 * 60);
const DEBOUNCE: Duration = Duration::from_millis(1_500);
const DEBOUNCE_CEILING: Duration = Duration::from_secs(6);
const REFOCUS_GAP: Duration = Duration::from_secs(10);
const RETRY_BASE: Duration = Duration::from_secs(5);

/// How a round ended, as far as the next wait is concerned.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Outcome {
    /// Everything local and remote is in step.
    Fine,
    /// Something failed that may pass: back off, with jitter.
    Failed,
    /// Nothing a retry can fix: wait for the slow poll or a nudge from the person.
    Parked,
}

#[derive(Clone, Copy)]
struct Debounce {
    first: Instant,
    due: Instant,
}

/// Decides when the worker syncs next. It holds no clock and no thread, so every rule is a plain test: the poll is 30 seconds while the window is focused and five minutes otherwise, a local write waits 1.5 seconds for company (never more than six), a failure backs off exponentially with jitter up to the poll interval, and network recovery or regaining focus tries again at once.
pub struct Scheduler {
    focused: bool,
    connected: bool,
    failures: u32,
    periodic: Option<Instant>,
    debounce: Option<Debounce>,
    last_run: Option<Instant>,
    jitter: fn() -> f64,
}

impl Scheduler {
    /// A scheduler that draws its jitter, a number in `[0, 1)`, from `jitter`.
    pub fn new(jitter: fn() -> f64) -> Self {
        Scheduler {
            focused: false,
            connected: false,
            failures: 0,
            periodic: None,
            debounce: None,
            last_run: None,
            jitter,
        }
    }

    /// A server is connected: sync now.
    pub fn connect(&mut self, now: Instant) {
        self.connected = true;
        self.failures = 0;
        self.periodic = Some(now);
    }

    /// The server was forgotten: nothing is scheduled.
    pub fn disconnect(&mut self) {
        *self = Scheduler::new(self.jitter);
    }

    /// The window gained or lost focus.
    pub fn focus(&mut self, focused: bool, now: Instant) {
        let gained = focused && !self.focused;
        self.focused = focused;
        if !self.connected {
            return;
        }
        if gained {
            self.periodic = Some(self.after_gap(now));
        } else if !focused && self.failures == 0 {
            self.periodic = Some(self.last_run.unwrap_or(now) + BACKGROUND_POLL);
        }
    }

    /// A local write happened.
    pub fn poke(&mut self, now: Instant) {
        if !self.connected {
            return;
        }
        let first = self.debounce.map_or(now, |pending| pending.first);
        let due = (now + DEBOUNCE).min(first + DEBOUNCE_CEILING);
        self.debounce = Some(Debounce { first, due });
    }

    /// The network came back.
    pub fn network_recovered(&mut self, now: Instant) {
        if self.connected {
            self.failures = 0;
            self.periodic = Some(now);
        }
    }

    /// When the worker should wake next, if ever.
    pub fn deadline(&self) -> Option<Instant> {
        let pending = self.debounce.map(|pending| pending.due);
        match (self.periodic, pending) {
            (Some(periodic), Some(pending)) => Some(periodic.min(pending)),
            (periodic, pending) => periodic.or(pending),
        }
    }

    /// True when a round is due.
    pub fn is_due(&self, now: Instant) -> bool {
        self.deadline().is_some_and(|deadline| deadline <= now)
    }

    /// A round starts: what asked for it is answered.
    pub fn begin(&mut self) {
        self.periodic = None;
        self.debounce = None;
    }

    /// A round ended.
    pub fn finish(&mut self, outcome: Outcome, now: Instant) {
        self.last_run = Some(now);
        let wait = match outcome {
            Outcome::Fine => {
                self.failures = 0;
                self.poll()
            }
            Outcome::Failed => {
                self.failures += 1;
                self.retry_delay()
            }
            Outcome::Parked => BACKGROUND_POLL,
        };
        self.periodic = Some(now + wait);
    }

    /// How many rounds in a row have failed.
    #[cfg(test)]
    pub fn failures(&self) -> u32 {
        self.failures
    }

    fn poll(&self) -> Duration {
        if self.focused {
            FOCUSED_POLL
        } else {
            BACKGROUND_POLL
        }
    }

    fn retry_delay(&self) -> Duration {
        let doubled = RETRY_BASE.saturating_mul(1 << (self.failures - 1).min(10));
        let ceiling = doubled.min(self.poll());
        ceiling.mul_f64(0.5 + 0.5 * (self.jitter)().clamp(0.0, 1.0))
    }

    fn after_gap(&self, now: Instant) -> Instant {
        match self.last_run {
            Some(last) => now.max(last + REFOCUS_GAP),
            None => now,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn half() -> f64 {
        0.0
    }

    fn scheduler() -> (Scheduler, Instant) {
        (Scheduler::new(half), Instant::now())
    }

    fn secs(seconds: u64) -> Duration {
        Duration::from_secs(seconds)
    }

    #[test]
    fn nothing_is_scheduled_without_a_server() {
        let (mut scheduler, start) = scheduler();
        scheduler.poke(start);
        scheduler.focus(true, start);
        scheduler.network_recovered(start);
        assert_eq!(scheduler.deadline(), None);
    }

    #[test]
    fn connecting_syncs_at_once_and_a_good_round_waits_for_the_poll() {
        let (mut scheduler, start) = scheduler();
        scheduler.focus(true, start);
        scheduler.connect(start);
        assert!(scheduler.is_due(start));
        scheduler.begin();
        scheduler.finish(Outcome::Fine, start);
        assert_eq!(scheduler.deadline(), Some(start + secs(30)));
        scheduler.focus(false, start + secs(1));
        assert_eq!(scheduler.deadline(), Some(start + secs(300)));
    }

    #[test]
    fn an_unfocused_window_polls_every_five_minutes() {
        let (mut scheduler, start) = scheduler();
        scheduler.connect(start);
        scheduler.begin();
        scheduler.finish(Outcome::Fine, start);
        assert_eq!(scheduler.deadline(), Some(start + secs(300)));
    }

    #[test]
    fn a_write_waits_a_second_and_a_half_and_more_writes_extend_it_up_to_six_seconds() {
        let (mut scheduler, start) = scheduler();
        scheduler.connect(start);
        scheduler.begin();
        scheduler.finish(Outcome::Fine, start);
        scheduler.poke(start + secs(10));
        assert_eq!(
            scheduler.deadline(),
            Some(start + secs(10) + Duration::from_millis(1_500))
        );
        for tick in 1..=20 {
            scheduler.poke(start + secs(10) + Duration::from_secs(tick));
        }
        assert_eq!(scheduler.deadline(), Some(start + secs(16)));
    }

    #[test]
    fn failures_back_off_by_doubling_and_stop_at_the_poll_interval() {
        let (mut scheduler, start) = scheduler();
        scheduler.focus(true, start);
        scheduler.connect(start);
        let mut now = start;
        let mut waits = Vec::new();
        for _ in 0..5 {
            scheduler.begin();
            scheduler.finish(Outcome::Failed, now);
            let wait = scheduler.deadline().unwrap() - now;
            waits.push(wait.as_secs_f64());
            now = scheduler.deadline().unwrap();
        }
        assert_eq!(waits, vec![2.5, 5.0, 10.0, 15.0, 15.0]);
        assert_eq!(scheduler.failures(), 5);
    }

    #[test]
    fn jitter_stays_between_half_and_all_of_the_delay() {
        fn full() -> f64 {
            0.999_999
        }
        let start = Instant::now();
        let mut scheduler = Scheduler::new(full);
        scheduler.connect(start);
        scheduler.begin();
        scheduler.finish(Outcome::Failed, start);
        let wait = scheduler.deadline().unwrap() - start;
        assert!(wait > Duration::from_millis(4_990) && wait <= secs(5));
    }

    #[test]
    fn recovering_the_network_or_gaining_focus_retries_at_once_but_not_in_a_burst() {
        let (mut scheduler, start) = scheduler();
        scheduler.connect(start);
        scheduler.begin();
        scheduler.finish(Outcome::Failed, start);
        scheduler.network_recovered(start + secs(1));
        assert_eq!(scheduler.deadline(), Some(start + secs(1)));
        assert_eq!(scheduler.failures(), 0);
        scheduler.begin();
        scheduler.finish(Outcome::Fine, start + secs(1));
        scheduler.focus(true, start + secs(3));
        assert_eq!(scheduler.deadline(), Some(start + secs(11)));
        scheduler.focus(false, start + secs(4));
        scheduler.focus(true, start + secs(40));
        assert_eq!(scheduler.deadline(), Some(start + secs(40)));
    }

    #[test]
    fn a_parked_round_waits_for_the_slow_poll_even_when_focused() {
        let (mut scheduler, start) = scheduler();
        scheduler.focus(true, start);
        scheduler.connect(start);
        scheduler.begin();
        scheduler.finish(Outcome::Parked, start);
        assert_eq!(scheduler.deadline(), Some(start + secs(300)));
    }

    #[test]
    fn disconnecting_forgets_everything() {
        let (mut scheduler, start) = scheduler();
        scheduler.connect(start);
        scheduler.poke(start);
        scheduler.disconnect();
        assert_eq!(scheduler.deadline(), None);
    }
}
