//! Mirrors `FlaccyCore/Sources/FlaccyCore/Library/LibrarySurface.swift`.
//!
//! Which launch chrome a client shows is one routing decision in tested shared
//! logic, not two booleans derived at delivery time — the frozen-1%-ring bug
//! was a routing bug.

use serde::{Deserialize, Serialize};

use crate::enrichment_job::{Activity, JobProgress};
use crate::load_progress::LoadProgress;

#[derive(Clone, Copy, PartialEq, Eq, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Surface {
    None,
    Ambient,
    Debut,
}

/// How long a background job must be visibly working before it earns an
/// ambient line, so a relaunch that finds nothing due never flashes one.
pub const AMBIENT_GRACE: f64 = 0.25;

#[derive(Clone, Copy, PartialEq, Eq, Debug, Default)]
pub struct SurfaceRouter {
    debut_latched: bool,
}

impl SurfaceRouter {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn route(
        &mut self,
        load: &LoadProgress,
        job: &JobProgress,
        debut_completed: bool,
        has_library: bool,
        elapsed: f64,
    ) -> Surface {
        if !debut_completed && !has_library && (load.phase.blocks_library() || self.debut_latched) {
            self.debut_latched = true;
            return Surface::Debut;
        }
        if self.debut_latched && !debut_completed {
            return Surface::Debut;
        }
        if load.is_active() && has_library {
            return Surface::Ambient;
        }
        if job.activity == Activity::Running || job.activity == Activity::WaitingForNetwork {
            if job.completed_this_run >= 1 && elapsed >= AMBIENT_GRACE {
                return Surface::Ambient;
            }
            return Surface::None;
        }
        Surface::None
    }

    /// Called once the summary card is dismissed (or the build produced no
    /// albums); the debut can never be re-entered for this launch.
    pub fn release_debut(&mut self) {
        self.debut_latched = false;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::enrichment_job::Scope;
    use crate::load_progress::LoadPhase;

    fn scanning() -> LoadProgress {
        LoadProgress::new(LoadPhase::ReadingTags)
    }

    fn working(completed: usize) -> JobProgress {
        JobProgress {
            activity: Activity::Running,
            scope: Scope::Album,
            remaining: 12,
            completed_this_run: completed,
            ..JobProgress::idle()
        }
    }

    #[test]
    fn relaunch_with_a_library_never_presents_the_debut() {
        let mut router = SurfaceRouter::new();
        let surface = router.route(&scanning(), &JobProgress::idle(), true, true, 10.0);
        assert_eq!(surface, Surface::Ambient);
    }

    #[test]
    fn first_build_presents_the_debut_immediately() {
        let mut router = SurfaceRouter::new();
        let surface = router.route(&scanning(), &JobProgress::idle(), false, false, 0.0);
        assert_eq!(surface, Surface::Debut);
    }

    #[test]
    fn debut_stays_presented_until_it_is_released() {
        let mut router = SurfaceRouter::new();
        assert_eq!(
            router.route(&scanning(), &JobProgress::idle(), false, false, 0.0),
            Surface::Debut
        );
        assert_eq!(
            router.route(&LoadProgress::default(), &JobProgress::idle(), false, true, 1.0),
            Surface::Debut
        );
        router.release_debut();
        assert_eq!(
            router.route(&LoadProgress::default(), &JobProgress::idle(), true, true, 1.0),
            Surface::None
        );
    }

    #[test]
    fn completed_debut_is_never_presented_again() {
        let mut router = SurfaceRouter::new();
        assert_eq!(
            router.route(&scanning(), &JobProgress::idle(), true, false, 0.0),
            Surface::None
        );
    }

    #[test]
    fn ambient_waits_for_the_grace() {
        let mut router = SurfaceRouter::new();
        assert_eq!(
            router.route(&LoadProgress::default(), &working(1), true, true, 0.1),
            Surface::None
        );
        assert_eq!(
            router.route(&LoadProgress::default(), &working(1), true, true, AMBIENT_GRACE),
            Surface::Ambient
        );
    }

    #[test]
    fn ambient_is_hidden_for_a_job_that_has_completed_nothing() {
        let mut router = SurfaceRouter::new();
        assert_eq!(
            router.route(&LoadProgress::default(), &working(0), true, true, 10.0),
            Surface::None
        );
    }

    #[test]
    fn ambient_appears_after_the_first_completion() {
        let mut router = SurfaceRouter::new();
        assert_eq!(
            router.route(&LoadProgress::default(), &working(1), true, true, 10.0),
            Surface::Ambient
        );
    }

    #[test]
    fn waiting_for_network_keeps_the_ambient_surface() {
        let mut router = SurfaceRouter::new();
        let mut job = working(3);
        job.activity = Activity::WaitingForNetwork;
        assert_eq!(
            router.route(&LoadProgress::default(), &job, true, true, 10.0),
            Surface::Ambient
        );
    }

    #[test]
    fn needs_entitlement_never_raises_the_ambient_surface() {
        let mut router = SurfaceRouter::new();
        let mut job = working(9);
        job.activity = Activity::NeedsEntitlement;
        assert_eq!(
            router.route(&LoadProgress::default(), &job, true, true, 10.0),
            Surface::None
        );
    }

    #[test]
    fn surface_is_none_when_nothing_is_happening() {
        let mut router = SurfaceRouter::new();
        assert_eq!(
            router.route(&LoadProgress::default(), &JobProgress::idle(), true, true, 10.0),
            Surface::None
        );
    }
}
