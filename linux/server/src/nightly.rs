//! The nightly backup task `serve` runs: 03:30 local time, jittered by up to ten minutes either way.
//!
//! A server that was off at 03:30 would otherwise never back up, so a start
//! with no successful backup in the last day schedules one five minutes in.
//! A failure is logged as a warning at most once a day and never stops the server.

use std::path::Path;
use std::time::Duration;

use chrono::{DateTime, Local, NaiveDate, TimeZone, Utc};
use flaccy_library::logger;

use crate::backup;
use crate::retention;
use crate::state::AppState;

const RUN_AT_HOUR: u32 = 3;
const RUN_AT_MINUTE: u32 = 30;
const JITTER_SECONDS: i64 = 10 * 60;
const CATCH_UP_DELAY: Duration = Duration::from_secs(5 * 60);
const CATCH_UP_AFTER_HOURS: i64 = 26;
const LONGEST_SLEEP: Duration = Duration::from_secs(60);
const CATEGORY: &str = "backup";

/// The scheduled moment on `date`, `jitter` seconds off 03:30 local time; `None` on a day with no such local time.
pub fn slot_on(date: NaiveDate, jitter: i64) -> Option<DateTime<Local>> {
    let nominal = date.and_hms_opt(RUN_AT_HOUR, RUN_AT_MINUTE, 0)?;
    let moment = Local.from_local_datetime(&nominal).earliest()?;
    Some(moment + chrono::Duration::seconds(jitter))
}

/// The first slot after `now`, today's if it is still ahead and tomorrow's if not.
pub fn upcoming(now: DateTime<Local>, jitter: i64) -> DateTime<Local> {
    let today = now.date_naive();
    (0..3)
        .filter_map(|offset| slot_on(today + chrono::Duration::days(offset), jitter))
        .find(|slot| *slot > now)
        .unwrap_or(now + chrono::Duration::hours(24))
}

/// The slot on the day after `ran_on`, so a run that drifted late or early never doubles up in one night.
pub fn following(ran_on: NaiveDate, now: DateTime<Local>, jitter: i64) -> DateTime<Local> {
    slot_on(ran_on + chrono::Duration::days(1), jitter).filter(|slot| *slot > now).unwrap_or_else(|| upcoming(now, jitter))
}

/// True when the last successful backup is missing or older than a day and two hours.
pub fn needs_catch_up(last_ok: Option<DateTime<Utc>>, now: DateTime<Utc>) -> bool {
    last_ok.is_none_or(|at| now - at > chrono::Duration::hours(CATCH_UP_AFTER_HOURS))
}

fn jitter() -> i64 {
    rand::random_range(-JITTER_SECONDS..=JITTER_SECONDS)
}

async fn last_success(state: &AppState) -> Option<DateTime<Utc>> {
    let status = backup::last_status(&state.0.security).await.ok()?;
    if status.last_ok != Some(true) {
        return None;
    }
    DateTime::parse_from_rfc3339(status.last_at.as_deref()?).ok().map(|at| at.with_timezone(&Utc))
}

async fn first_due(state: &AppState) -> DateTime<Local> {
    let now = Local::now();
    if needs_catch_up(last_success(state).await, Utc::now()) {
        return now + chrono::Duration::from_std(CATCH_UP_DELAY).unwrap_or_default();
    }
    upcoming(now, jitter())
}

async fn sleep_until(due: DateTime<Local>) {
    loop {
        let remaining = (due - Local::now()).to_std().unwrap_or_default();
        if remaining.is_zero() {
            return;
        }
        tokio::time::sleep(remaining.min(LONGEST_SLEEP)).await;
    }
}

async fn prune_after(dir: &Path) {
    let dir = dir.to_path_buf();
    match tokio::task::spawn_blocking(move || retention::prune(&dir)).await {
        Ok(Ok(0)) => {}
        Ok(Ok(removed)) => logger::info(CATEGORY, &format!("removed {removed} expired backup file(s)")),
        Ok(Err(error)) => logger::warn(CATEGORY, &format!("could not prune old backups: {error}")),
        Err(error) => logger::warn(CATEGORY, &format!("the pruning thread stopped unexpectedly: {error}")),
    }
}

/// Makes one verified backup into the configured folder, records the outcome, and prunes only after a success.
pub async fn run_once(state: &AppState, dir: &Path) -> Result<backup::BackupSet, String> {
    let outcome = backup::back_up(&state.0.config, dir.to_path_buf()).await;
    if let Err(error) = backup::record_outcome(&state.0.security, &outcome).await {
        logger::warn(CATEGORY, &format!("could not record the backup status: {error}"));
    }
    if let Ok(set) = &outcome {
        logger::info(CATEGORY, &format!("backed up to {} and {}", set.state.path.display(), set.security.path.display()));
        prune_after(dir).await;
    }
    outcome
}

fn warn_once_a_day(warned_on: &mut Option<NaiveDate>, error: &str) {
    let today = Local::now().date_naive();
    if *warned_on == Some(today) {
        return;
    }
    *warned_on = Some(today);
    logger::warn(
        CATEGORY,
        &format!("the nightly backup failed: {error} The server keeps running; fix the cause and run `flaccy-server backup` to check."),
    );
}

/// Runs the nightly backup for as long as the task lives; returns at once when `backup_dir` is empty.
pub async fn keep_backed_up(state: AppState) {
    let Some(dir) = state.0.config.backup_dir() else {
        logger::info(CATEGORY, "nightly backups are off because `backup_dir` is empty");
        return;
    };
    let mut warned_on = None;
    let mut due = first_due(&state).await;
    loop {
        sleep_until(due).await;
        let ran_on = Local::now().date_naive();
        if let Err(error) = run_once(&state, &dir).await {
            warn_once_a_day(&mut warned_on, &error);
        }
        due = following(ran_on, Local::now(), jitter());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn local(year: i32, month: u32, day: u32, hour: u32, minute: u32) -> DateTime<Local> {
        Local.with_ymd_and_hms(year, month, day, hour, minute, 0).unwrap()
    }

    #[test]
    fn before_half_past_three_the_slot_is_today_and_after_it_is_tomorrow() {
        let early = upcoming(local(2026, 10, 26, 1, 0), 0);
        assert_eq!((early.date_naive(), early.format("%H:%M").to_string()), (NaiveDate::from_ymd_opt(2026, 10, 26).unwrap(), "03:30".to_owned()));
        let late = upcoming(local(2026, 10, 26, 9, 0), 0);
        assert_eq!(late.date_naive(), NaiveDate::from_ymd_opt(2026, 10, 27).unwrap());
    }

    #[test]
    fn the_jitter_moves_the_slot_within_ten_minutes() {
        let base = slot_on(NaiveDate::from_ymd_opt(2026, 10, 26).unwrap(), 0).unwrap();
        let earliest = slot_on(NaiveDate::from_ymd_opt(2026, 10, 26).unwrap(), -JITTER_SECONDS).unwrap();
        let latest = slot_on(NaiveDate::from_ymd_opt(2026, 10, 26).unwrap(), JITTER_SECONDS).unwrap();
        assert_eq!((base - earliest).num_minutes(), 10);
        assert_eq!((latest - base).num_minutes(), 10);
        assert!((0..50).map(|_| jitter()).all(|value| value.abs() <= JITTER_SECONDS));
    }

    #[test]
    fn a_run_that_drifted_never_doubles_up_the_same_night() {
        let ran_on = NaiveDate::from_ymd_opt(2026, 10, 26).unwrap();
        let next = following(ran_on, local(2026, 10, 26, 3, 21), 600);
        assert_eq!(next.date_naive(), NaiveDate::from_ymd_opt(2026, 10, 27).unwrap());
    }

    #[test]
    fn a_missing_or_day_old_success_asks_for_a_catch_up_run() {
        let now = Utc::now();
        assert!(needs_catch_up(None, now));
        assert!(needs_catch_up(Some(now - chrono::Duration::hours(30)), now));
        assert!(!needs_catch_up(Some(now - chrono::Duration::hours(3)), now));
    }

    #[test]
    fn a_failure_warns_once_per_day() {
        let mut warned = None;
        warn_once_a_day(&mut warned, "disk full.");
        assert_eq!(warned, Some(Local::now().date_naive()));
        warn_once_a_day(&mut warned, "disk full.");
    }
}
