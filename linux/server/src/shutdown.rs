//! Stopping cleanly: stop accepting, give open requests ten seconds, then let the database writers finish and empty their logs.

use std::future::Future;
use std::time::Duration;

use flaccy_library::logger;
use tokio::sync::watch;

use crate::state::AppState;

/// How long open requests get after a stop request before the server stops waiting for them.
pub const GRACE: Duration = Duration::from_secs(10);

/// Flips once when the process is asked to stop; clones all see it.
#[derive(Clone)]
pub struct StopSignal {
    sender: watch::Sender<bool>,
}

impl Default for StopSignal {
    fn default() -> Self {
        Self::new()
    }
}

impl StopSignal {
    /// A signal that has not been raised.
    pub fn new() -> Self {
        Self { sender: watch::channel(false).0 }
    }

    /// Raises the signal.
    pub fn raise(&self) {
        self.sender.send_replace(true);
    }

    /// Resolves once the signal is raised.
    pub async fn raised(&self) {
        let mut receiver = self.sender.subscribe();
        let _ = receiver.wait_for(|raised| *raised).await;
    }
}

/// Runs `server` until it ends on its own; once `stop` is raised it gets `grace` to finish and is then dropped.
/// Returns `None` when the grace period ran out.
pub async fn run_until_stopped<F: Future>(server: F, stop: &StopSignal, grace: Duration) -> Option<F::Output> {
    tokio::pin!(server);
    tokio::select! {
        outcome = &mut server => Some(outcome),
        () = async {
            stop.raised().await;
            tokio::time::sleep(grace).await;
        } => None,
    }
}

/// Finishes the work queued on both databases, empties their write-ahead logs and closes them.
///
/// A request that arrives afterwards finds the databases closed and fails
/// with the usual "database thread has stopped" error, which is the right
/// answer for a server that is going away.
pub async fn close_databases(state: &AppState) {
    if let Err(error) = state.0.sync.close().await {
        logger::warn("server", &format!("state.sqlite did not close cleanly: {error}"));
    }
    if let Err(error) = state.0.security.close().await {
        logger::warn("server", &format!("security.sqlite did not close cleanly: {error}"));
    }
    logger::info("server", "databases closed");
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::future::pending;

    const SHORT_GRACE: Duration = Duration::from_millis(150);

    #[tokio::test]
    async fn a_server_that_ends_by_itself_returns_its_result() {
        let stop = StopSignal::new();
        let outcome = run_until_stopped(async { 7 }, &stop, GRACE).await;
        assert_eq!(outcome, Some(7));
    }

    #[tokio::test]
    async fn a_server_that_never_drains_is_dropped_after_the_grace_period() {
        let stop = StopSignal::new();
        let waiting = stop.clone();
        let handle = tokio::spawn(async move { run_until_stopped(pending::<()>(), &waiting, SHORT_GRACE).await });
        tokio::time::sleep(SHORT_GRACE * 2).await;
        assert!(!handle.is_finished(), "nothing happens before the stop request");
        let raised_at = std::time::Instant::now();
        stop.raise();
        assert_eq!(handle.await.unwrap(), None);
        assert!(raised_at.elapsed() >= SHORT_GRACE);
    }

    #[tokio::test]
    async fn a_server_that_drains_within_the_grace_period_is_allowed_to() {
        let stop = StopSignal::new();
        let draining = stop.clone();
        let server = async move {
            draining.raised().await;
            tokio::time::sleep(SHORT_GRACE / 3).await;
            "drained"
        };
        let handle = tokio::spawn({
            let stop = stop.clone();
            async move { run_until_stopped(server, &stop, SHORT_GRACE).await }
        });
        stop.raise();
        assert_eq!(handle.await.unwrap(), Some("drained"));
    }
}
