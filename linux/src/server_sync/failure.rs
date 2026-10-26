use super::copy;
use flaccy_library::server_sync::{ApiError, Incompatibility, SyncError};

/// Which call failed, because the same answer means different things to each.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Stage {
    /// The first look at the address (`GET /hello`).
    Probe,
    /// Redeeming the code (`POST /devices`).
    Enroll,
    /// Any later call on a connected server.
    Connected,
}

/// What the dialog offers after a failure.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Remedy {
    /// Go back to the fields and try again.
    TryAgain,
    /// Close the failure.
    Ok,
    /// Offer the OpenSubsonic Add Server sheet for the same address.
    AddAsRegular,
}

/// A failure as the person reads it: what failed, the cause and the next step.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Failure {
    /// The heading.
    pub title: String,
    /// The explanation and what to do.
    pub body: String,
    /// The button the failure ends with.
    pub remedy: Remedy,
}

impl Failure {
    fn new(title: impl Into<String>, body: impl Into<String>, remedy: Remedy) -> Self {
        Failure {
            title: title.into(),
            body: body.into(),
            remedy,
        }
    }
}

/// Maps what the sync engine reported onto the failure table of `docs/server/UX.md`.
pub fn failure_for(error: &SyncError, stage: Stage, name: &str) -> Failure {
    match error {
        SyncError::Incompatible(Incompatibility::ServerTooOld) => Failure::new(
            copy::SERVER_TOO_OLD_TITLE,
            copy::SERVER_TOO_OLD_BODY,
            Remedy::Ok,
        ),
        SyncError::Incompatible(Incompatibility::AppTooOld) => Failure::new(
            copy::APP_TOO_OLD_TITLE,
            copy::app_too_old_body(name),
            Remedy::Ok,
        ),
        SyncError::Api(api) => api_failure(api, stage, name),
        other => generic(name, &other.to_string()),
    }
}

fn api_failure(error: &ApiError, stage: Stage, name: &str) -> Failure {
    match (error, stage) {
        (ApiError::Offline(cause), _) if is_name_lookup(cause) => Failure::new(
            copy::cant_find_title(name),
            copy::CANT_FIND_BODY,
            Remedy::TryAgain,
        ),
        (ApiError::Offline(_), _) => Failure::new(
            copy::cant_reach_title(name),
            copy::cant_reach_body(name),
            Remedy::TryAgain,
        ),
        (ApiError::Unauthorized, Stage::Enroll) => Failure::new(
            copy::CODE_REFUSED_TITLE,
            copy::code_refused_body(name),
            Remedy::TryAgain,
        ),
        (ApiError::Unauthorized, Stage::Connected) => {
            Failure::new(copy::revoked_title(name), copy::REVOKED_BODY, Remedy::Ok)
        }
        (ApiError::InsufficientStorage, _) => Failure::new(
            copy::disk_full_title(name),
            copy::DISK_FULL_BODY,
            Remedy::Ok,
        ),
        (ApiError::RateLimited(_), Stage::Enroll) => {
            Failure::new(copy::TOO_MANY_TITLE, copy::TOO_MANY_BODY, Remedy::Ok)
        }
        (ApiError::ClockBehind, _) => {
            Failure::new(copy::clock_title(name), copy::CLOCK_BODY, Remedy::Ok)
        }
        (ApiError::Malformed(_) | ApiError::Refused { .. }, Stage::Probe) => Failure::new(
            copy::not_flaccy_title(name),
            copy::NOT_FLACCY_BODY,
            Remedy::AddAsRegular,
        ),
        (other, _) => generic(name, &other.to_string()),
    }
}

fn generic(name: &str, cause: &str) -> Failure {
    Failure::new(
        copy::generic_title(name),
        copy::generic_body(cause),
        Remedy::TryAgain,
    )
}

/// Whether a transport failure was the name not resolving, as ureq words it.
fn is_name_lookup(cause: &str) -> bool {
    cause == ureq::ErrorKind::Dns.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn api(error: ApiError, stage: Stage) -> Failure {
        failure_for(&SyncError::Api(error), stage, "arch")
    }

    #[test]
    fn an_unreachable_server_asks_about_tailscale() {
        let failure = api(ApiError::Offline("Connection Failed".into()), Stage::Probe);
        assert_eq!(failure.title, "Can't reach arch");
        assert_eq!(
            failure.body,
            "Is Tailscale on? Open Tailscale and connect on this device and on arch, then try again."
        );
        assert_eq!(failure.remedy, Remedy::TryAgain);
    }

    #[test]
    fn a_name_that_does_not_resolve_is_not_found() {
        let cause = ureq::ErrorKind::Dns.to_string();
        let failure = api(ApiError::Offline(cause), Stage::Probe);
        assert_eq!(failure.title, "Can't find arch");
        assert!(failure.body.contains("tailscale status"));
    }

    #[test]
    fn a_refused_code_is_the_code_failure_only_when_enrolling() {
        let failure = api(ApiError::Unauthorized, Stage::Enroll);
        assert_eq!(failure.title, "That code didn't work");
        assert_eq!(
            failure.body,
            "A code works once and expires after 10 minutes. On arch, run `flaccy-server enroll` for a new one."
        );
        assert_ne!(
            api(ApiError::Unauthorized, Stage::Connected).title,
            failure.title
        );
    }

    #[test]
    fn a_revoked_device_and_a_full_disk_say_what_to_do() {
        let revoked = api(ApiError::Unauthorized, Stage::Connected);
        assert_eq!(revoked.title, "arch no longer accepts this device");
        assert_eq!(revoked.body, "Disconnect it, then add the server again.");
        let full = api(ApiError::InsufficientStorage, Stage::Enroll);
        assert_eq!(full.title, "arch is out of disk space");
        assert_eq!(full.body, "Free some up and Flaccy retries by itself.");
    }

    #[test]
    fn five_wrong_codes_ask_to_wait() {
        let failure = api(ApiError::RateLimited(Some(60)), Stage::Enroll);
        assert_eq!(failure.title, "Too many tries");
        assert_eq!(failure.remedy, Remedy::Ok);
    }

    #[test]
    fn another_kind_of_server_offers_the_regular_flow() {
        for error in [
            ApiError::Malformed("html".into()),
            ApiError::Refused {
                status: 404,
                code: String::new(),
            },
        ] {
            let failure = api(error, Stage::Probe);
            assert_eq!(failure.title, "arch isn't a Flaccy Server");
            assert_eq!(failure.remedy, Remedy::AddAsRegular);
        }
    }

    #[test]
    fn versions_and_clocks_have_their_own_titles() {
        let old_server = failure_for(
            &SyncError::Incompatible(Incompatibility::ServerTooOld),
            Stage::Probe,
            "arch",
        );
        assert_eq!(old_server.title, "Update your Flaccy Server");
        let old_app = failure_for(
            &SyncError::Incompatible(Incompatibility::AppTooOld),
            Stage::Probe,
            "arch",
        );
        assert_eq!(old_app.title, "Update Flaccy");
        assert_eq!(old_app.body, "arch needs a newer Flaccy than this one.");
        let clock = api(ApiError::ClockBehind, Stage::Enroll);
        assert_eq!(clock.title, "The clock on arch is wrong");
    }

    #[test]
    fn anything_else_names_the_cause_and_the_next_step() {
        let failure = api(ApiError::Server(500), Stage::Enroll);
        assert_eq!(failure.title, "Couldn't connect to arch");
        assert!(failure.body.contains("status 500"));
        assert!(failure.body.contains("flaccy-server doctor"));
    }
}
