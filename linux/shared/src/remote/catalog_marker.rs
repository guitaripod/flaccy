//! Mirrors `Core/FlaccyCore/Sources/FlaccyCore/Remote/RemoteCatalogMarker.swift`.
//!
//! Whether a server's library changed since the last catalog sync, told by one
//! `getScanStatus` call instead of listing every song. A sync remembers the
//! marker it read just before it listed the songs; a later marker that differs
//! means songs arrived, left or changed there. `lastScan` decides when the
//! server reports it, the song count otherwise, and a server that reports
//! neither is left to the periodic sync.

use super::subsonic_response::ScanStatus;

/// What a server said about its library at one moment.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct CatalogMarker {
    pub last_scan: Option<String>,
    pub count: Option<i64>,
}

impl CatalogMarker {
    /// The marker in a `getScanStatus` answer; blank `lastScan` counts as absent.
    pub fn from_status(status: &ScanStatus) -> Self {
        Self {
            last_scan: status.last_scan.as_deref().map(str::trim).filter(|text| !text.is_empty()).map(str::to_string),
            count: status.count,
        }
    }

    /// Whether the library behind `current` differs from the one this marker was read from. With nothing
    /// remembered the answer is yes, so the first probe after a launch or an update syncs once.
    pub fn changed(remembered: Option<&CatalogMarker>, current: &CatalogMarker) -> bool {
        let Some(remembered) = remembered else {
            return true;
        };
        if current.last_scan.is_some() {
            return remembered.last_scan != current.last_scan;
        }
        current.count.is_some() && remembered.count != current.count
    }

    /// One line for storage: the count, a tab, then `lastScan`.
    pub fn encoded(&self) -> String {
        format!(
            "{}\t{}",
            self.count.map(|count| count.to_string()).unwrap_or_default(),
            self.last_scan.as_deref().unwrap_or_default()
        )
    }

    /// The marker [`encoded`](Self::encoded) wrote, `None` for text it could not have written.
    pub fn decoded(text: &str) -> Option<Self> {
        let (count, last_scan) = text.split_once('\t')?;
        let count = match count {
            "" => None,
            digits => Some(digits.parse().ok()?),
        };
        Some(Self { last_scan: Some(last_scan.to_string()).filter(|text| !text.is_empty()), count })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn marker(last_scan: Option<&str>, count: Option<i64>) -> CatalogMarker {
        CatalogMarker { last_scan: last_scan.map(str::to_string), count }
    }

    #[test]
    fn nothing_remembered_means_changed() {
        assert!(CatalogMarker::changed(None, &marker(Some("2026-11-21T16:57:55.328Z"), Some(8081))));
        assert!(CatalogMarker::changed(None, &marker(None, None)));
    }

    #[test]
    fn last_scan_decides_when_the_server_reports_it() {
        let seen = marker(Some("2026-11-21T16:57:55.328Z"), Some(8081));
        assert!(!CatalogMarker::changed(Some(&seen), &marker(Some("2026-11-21T16:57:55.328Z"), Some(8081))));
        assert!(CatalogMarker::changed(Some(&seen), &marker(Some("2026-11-21T17:05:00.000Z"), Some(8081))));
        assert!(!CatalogMarker::changed(Some(&seen), &marker(Some("2026-11-21T16:57:55.328Z"), Some(8090))));
    }

    #[test]
    fn the_count_decides_without_last_scan() {
        let seen = marker(None, Some(8081));
        assert!(!CatalogMarker::changed(Some(&seen), &marker(None, Some(8081))));
        assert!(CatalogMarker::changed(Some(&seen), &marker(None, Some(8129))));
        assert!(CatalogMarker::changed(Some(&marker(Some("2026-11-21T16:57:55.328Z"), Some(8081))), &marker(None, Some(8129))));
    }

    #[test]
    fn a_server_that_reports_neither_is_left_to_the_periodic_sync() {
        assert!(!CatalogMarker::changed(Some(&marker(None, None)), &marker(None, None)));
        assert!(!CatalogMarker::changed(Some(&marker(None, Some(5))), &marker(None, None)));
    }

    #[test]
    fn reads_the_marker_from_a_scan_status_and_ignores_a_blank_last_scan() {
        let status = ScanStatus { scanning: false, count: Some(48), last_scan: Some("  ".to_string()) };
        assert_eq!(CatalogMarker::from_status(&status), marker(None, Some(48)));
        let status = ScanStatus { scanning: true, count: None, last_scan: Some("2026-11-21T16:57:55Z".to_string()) };
        assert_eq!(CatalogMarker::from_status(&status), marker(Some("2026-11-21T16:57:55Z"), None));
    }

    #[test]
    fn storage_round_trips_and_refuses_foreign_text() {
        for value in [marker(Some("2026-11-21T16:57:55.328Z"), Some(8081)), marker(None, Some(0)), marker(None, None), marker(Some("x"), None)] {
            assert_eq!(CatalogMarker::decoded(&value.encoded()), Some(value.clone()), "{value:?}");
        }
        assert_eq!(marker(Some("2026-11-21T16:57:55.328Z"), Some(8081)).encoded(), "8081\t2026-11-21T16:57:55.328Z");
        assert_eq!(CatalogMarker::decoded("no tab"), None);
        assert_eq!(CatalogMarker::decoded("eight\t"), None);
    }
}
