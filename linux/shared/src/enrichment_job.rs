//! Mirrors `FlaccyCore/Sources/FlaccyCore/Library/EnrichmentJob.swift`.
//!
//! Enrichment is a durable job, not a phase of a progress bar: one row per
//! entity, an explicit terminal negative cache, a producer version for
//! selective invalidation, and transport failures that never burn an attempt.
//! `is_due` is the only thing in either codebase allowed to gate an attempt.

use chrono::{DateTime, Duration, SecondsFormat, Utc};
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, PartialEq, Eq, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Scope {
    Album,
    Artist,
    AiBatch,
}

impl Scope {
    pub const ALL: [Scope; 3] = [Scope::Album, Scope::Artist, Scope::AiBatch];

    pub fn current_version(self) -> i64 {
        match self {
            Scope::Album => 1,
            Scope::Artist => 1,
            Scope::AiBatch => 1,
        }
    }

    pub fn max_attempts(self) -> i64 {
        match self {
            Scope::Album => 4,
            Scope::Artist => 3,
            Scope::AiBatch => 3,
        }
    }

    /// The `scope` column value, identical to the Swift raw value and to the
    /// literals in the SQL seeds.
    pub fn as_str(self) -> &'static str {
        match self {
            Scope::Album => "album",
            Scope::Artist => "artist",
            Scope::AiBatch => "aiBatch",
        }
    }

    pub fn parse(value: &str) -> Option<Scope> {
        Scope::ALL.into_iter().find(|scope| scope.as_str() == value)
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug, Serialize, Deserialize)]
#[serde(try_from = "i64", into = "i64")]
pub enum Status {
    Pending,
    Satisfied,
    Exhausted,
    Partial,
}

impl Status {
    pub fn as_i64(self) -> i64 {
        match self {
            Status::Pending => 0,
            Status::Satisfied => 1,
            Status::Exhausted => 2,
            Status::Partial => 3,
        }
    }
}

impl TryFrom<i64> for Status {
    type Error = &'static str;

    fn try_from(value: i64) -> Result<Self, Self::Error> {
        match value {
            0 => Ok(Status::Pending),
            1 => Ok(Status::Satisfied),
            2 => Ok(Status::Exhausted),
            3 => Ok(Status::Partial),
            _ => Err("unknown enrichment status"),
        }
    }
}

impl From<Status> for i64 {
    fn from(value: Status) -> i64 {
        value.as_i64()
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Failure {
    Transport,
    NotFound,
    RateLimited,
    Unauthorized,
}

impl Failure {
    pub const ALL: [Failure; 4] = [
        Failure::Transport,
        Failure::NotFound,
        Failure::RateLimited,
        Failure::Unauthorized,
    ];

    pub fn as_str(self) -> &'static str {
        match self {
            Failure::Transport => "transport",
            Failure::NotFound => "notFound",
            Failure::RateLimited => "rateLimited",
            Failure::Unauthorized => "unauthorized",
        }
    }

    pub fn parse(value: &str) -> Option<Failure> {
        Failure::ALL
            .into_iter()
            .find(|failure| failure.as_str() == value)
    }
}

/// A plain `i64` bitmask rather than a `bitflags` dependency — the shared crate
/// stays buildable anywhere, which is the whole reason it exists.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Default, Serialize, Deserialize)]
#[serde(transparent)]
pub struct Fields(pub i64);

impl Fields {
    pub const NONE: Fields = Fields(0);
    pub const COVER: Fields = Fields(1 << 0);
    pub const YEAR: Fields = Fields(1 << 1);
    pub const GENRE: Fields = Fields(1 << 2);
    pub const MBID: Fields = Fields(1 << 3);
    pub const ARTIST_BIO: Fields = Fields(1 << 4);
    pub const ARTIST_IMAGE: Fields = Fields(1 << 5);
    pub const IDENTIFIED: Fields = Fields(1 << 6);

    /// What must be present for an entity to be settled. Genre is deliberately
    /// excluded: MusicBrainz routinely returns an empty tag array, so requiring
    /// it makes a correctly-tagged album unsatisfiable forever.
    pub fn required(scope: Scope) -> Fields {
        match scope {
            Scope::Album => Fields(Fields::COVER.0 | Fields::YEAR.0),
            Scope::Artist => Fields::ARTIST_IMAGE,
            Scope::AiBatch => Fields::IDENTIFIED,
        }
    }

    pub const fn union(self, other: Fields) -> Fields {
        Fields(self.0 | other.0)
    }

    pub const fn contains(self, other: Fields) -> bool {
        self.0 & other.0 == other.0
    }

    pub fn form_union(&mut self, other: Fields) {
        self.0 |= other.0;
    }
}

#[derive(Clone, PartialEq, Eq, Debug, Serialize, Deserialize)]
pub struct EnrichmentRecord {
    pub scope: Scope,
    pub key: String,
    pub version: i64,
    pub status: Status,
    pub fields: Fields,
    pub attempts: i64,
    pub last_attempt_at: Option<DateTime<Utc>>,
    pub next_eligible_at: Option<DateTime<Utc>>,
    pub last_failure: Option<Failure>,
}

impl EnrichmentRecord {
    pub fn new(scope: Scope, key: impl Into<String>) -> Self {
        Self {
            scope,
            key: key.into(),
            version: 0,
            status: Status::Pending,
            fields: Fields::NONE,
            attempts: 0,
            last_attempt_at: None,
            next_eligible_at: None,
            last_failure: None,
        }
    }

    /// The `enrichmentState` row, in column order, so every caller writes the
    /// same shape and the timestamp encoding lives in exactly one place.
    pub fn columns(&self) -> RecordColumns {
        RecordColumns {
            scope: self.scope.as_str(),
            key: self.key.clone(),
            version: self.version,
            status: self.status.as_i64(),
            fields: self.fields.0,
            attempts: self.attempts,
            last_attempt_at: self.last_attempt_at.map(encode_timestamp),
            next_eligible_at: self.next_eligible_at.map(encode_timestamp),
            last_failure: self.last_failure.map(Failure::as_str),
        }
    }

    #[allow(clippy::too_many_arguments)]
    pub fn from_columns(
        scope: &str,
        key: impl Into<String>,
        version: i64,
        status: i64,
        fields: i64,
        attempts: i64,
        last_attempt_at: Option<&str>,
        next_eligible_at: Option<&str>,
        last_failure: Option<&str>,
    ) -> Option<Self> {
        Some(Self {
            scope: Scope::parse(scope)?,
            key: key.into(),
            version,
            status: Status::try_from(status).ok()?,
            fields: Fields(fields),
            attempts,
            last_attempt_at: last_attempt_at.and_then(decode_timestamp),
            next_eligible_at: next_eligible_at.and_then(decode_timestamp),
            last_failure: last_failure.and_then(Failure::parse),
        })
    }
}

#[derive(Clone, PartialEq, Eq, Debug)]
pub struct RecordColumns {
    pub scope: &'static str,
    pub key: String,
    pub version: i64,
    pub status: i64,
    pub fields: i64,
    pub attempts: i64,
    pub last_attempt_at: Option<String>,
    pub next_eligible_at: Option<String>,
    pub last_failure: Option<&'static str>,
}

/// 1 day, then 7, then 30, then terminal.
pub const BACKOFF_SECONDS: [i64; 3] = [86_400, 7 * 86_400, 30 * 86_400];

/// How long a rate-limited source is left alone, without burning an attempt.
pub const RATE_LIMIT_DEFERRAL_SECONDS: i64 = 15 * 60;

/// Consecutive transport outcomes after which a pass stops guessing and parks
/// until the route genuinely changes. Transport failures write nothing durable,
/// so parking costs the queue nothing and spares a captive portal five more
/// round trips per page. Mirrors `EnrichmentPolicy.transportFailuresBeforeWaiting`.
pub const TRANSPORT_FAILURES_BEFORE_WAITING: i64 = 5;

/// Satisfaction is re-derived from `fields` on every read rather than trusted
/// from `status`, so widening `Fields::required` in a future release revives
/// exactly the entities that no longer meet the bar, with no migration.
pub fn is_due(record: Option<&EnrichmentRecord>, scope: Scope, now: DateTime<Utc>) -> bool {
    let Some(record) = record else { return true };
    if record.fields.contains(Fields::required(scope)) {
        return false;
    }
    match record.status {
        Status::Satisfied | Status::Pending => true,
        Status::Exhausted => record.version < scope.current_version(),
        Status::Partial => {
            record.version < scope.current_version()
                || record.next_eligible_at.unwrap_or(now) <= now
        }
    }
}

/// Applies one attempt's outcome. `attempts` and `next_eligible_at` are left
/// untouched for failures the sources never actually answered, which is what
/// makes an entirely offline launch cost zero durable state.
pub fn apply(
    record: &mut EnrichmentRecord,
    scope: Scope,
    resolved: Fields,
    failure: Option<Failure>,
    now: DateTime<Utc>,
) {
    record.version = scope.current_version();
    record.fields.form_union(resolved);
    record.last_failure = failure;

    match failure {
        Some(Failure::Transport) | Some(Failure::Unauthorized) => {
            record.status = if record.fields.contains(Fields::required(scope)) {
                Status::Satisfied
            } else {
                Status::Pending
            };
            record.next_eligible_at = None;
            return;
        }
        Some(Failure::RateLimited) => {
            record.status = Status::Partial;
            record.last_attempt_at = Some(now);
            record.next_eligible_at = Some(now + Duration::seconds(RATE_LIMIT_DEFERRAL_SECONDS));
            return;
        }
        Some(Failure::NotFound) | None => {
            record.attempts += 1;
            record.last_attempt_at = Some(now);
        }
    }

    if record.fields.contains(Fields::required(scope)) {
        record.status = Status::Satisfied;
        record.next_eligible_at = None;
    } else if record.attempts >= scope.max_attempts() {
        record.status = Status::Exhausted;
        record.next_eligible_at = None;
    } else {
        let step = (record.attempts - 1).clamp(0, BACKOFF_SECONDS.len() as i64 - 1) as usize;
        record.status = Status::Partial;
        record.next_eligible_at = Some(now + Duration::seconds(BACKOFF_SECONDS[step]));
    }
}

pub const KEY_SEPARATOR: char = '\u{1F}';

pub fn key_album(title: &str, artist: &str) -> String {
    let mut key = normalize(title);
    key.push(KEY_SEPARATOR);
    key.push_str(&normalize(artist));
    key
}

pub fn key_artist(name: &str) -> String {
    normalize(name)
}

/// The directory `Library.analyzeLibrary` batches by: the file's parent path
/// with no trailing slash, or "" for a track at the library root.
pub fn key_ai_batch(directory: &str) -> String {
    normalize(directory)
}

/// The Rust twin of the SQL `rtrim(path, replace(path, '/', ''))` idiom the
/// seeds use, so a batch key derived here and one derived in SQLite agree.
pub fn ai_batch_directory(file_path: &str) -> &str {
    match file_path.rfind('/') {
        Some(index) => file_path[..index + 1].trim_end_matches('/'),
        None => "",
    }
}

/// The name every statement in this file calls to derive a key. It is a
/// deterministic scalar function registered on each connection over
/// [`normalize`], because SQLite's own `lower()` is ASCII-only and its `trim()`
/// strips spaces alone — so an album titled "Ágætis byrjun" would otherwise be
/// keyed one way by the queue and another by the code that reads and writes the
/// row, and the orphan sweep would delete the state on every scan.
pub const NORM_FN: &str = "flaccy_norm";

/// The single definition of a key component, shared by the Rust code and — via
/// [`NORM_FN`] — by every SQL statement here.
pub fn normalize(value: &str) -> String {
    compose(value.trim().to_lowercase().as_str())
}

/// Canonical composition over the Latin ranges music tags actually carry. A
/// full NFC implementation would mean a new dependency for a crate whose point
/// is having none; the pairs below are the ones `precomposedStringWithCanonicalMapping`
/// and this function have to agree on, and `composition_table_is_well_formed`
/// checks the table itself.
fn compose(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for ch in value.chars() {
        match out.pop() {
            Some(base) => match composed(base, ch) {
                Some(pair) => out.push(pair),
                None => {
                    out.push(base);
                    out.push(ch);
                }
            },
            None => out.push(ch),
        }
    }
    out
}

fn composed(base: char, mark: char) -> Option<char> {
    let (_, bases, composed) = COMPOSITIONS.iter().find(|(candidate, _, _)| *candidate == mark)?;
    let index = bases.chars().position(|candidate| candidate == base)?;
    composed.chars().nth(index)
}

const COMPOSITIONS: &[(char, &str, &str)] = &[
    ('\u{0300}', "aeinouy", "àèìǹòùỳ"),
    ('\u{0301}', "aceginorsuyz", "áćéǵíńóŕśúýź"),
    ('\u{0302}', "aceghijosuwy", "âĉêĝĥîĵôŝûŵŷ"),
    ('\u{0303}', "aeinou", "ãẽĩñõũ"),
    ('\u{0304}', "aeiou", "āēīōū"),
    ('\u{0306}', "aegiou", "ăĕğĭŏŭ"),
    ('\u{0307}', "cegz", "ċėġż"),
    ('\u{0308}', "aeiouy", "äëïöüÿ"),
    ('\u{0309}', "aeiouy", "ảẻỉỏủỷ"),
    ('\u{030a}', "au", "åů"),
    ('\u{030b}', "ou", "őű"),
    ('\u{030c}', "cdeghlnrstz", "čďěǧȟľňřšťž"),
    ('\u{0323}', "aeiouy", "ạẹịọụỵ"),
    ('\u{0327}', "cgklnrst", "çģķļņŗşţ"),
    ('\u{0328}', "aeiou", "ąęįǫų"),
];

pub fn encode_timestamp(value: DateTime<Utc>) -> String {
    value.to_rfc3339_opts(SecondsFormat::Secs, true)
}

pub fn decode_timestamp(value: &str) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(value)
        .ok()
        .map(|value| value.with_timezone(&Utc))
}

#[derive(Clone, Copy, PartialEq, Eq, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Activity {
    Idle,
    Running,
    WaitingForNetwork,
    NeedsEntitlement,
}

/// Deliberately fraction-free: the job is unbounded network work, so it is
/// reported as a countdown. A client that wants a bar would have to invent one.
#[derive(Clone, PartialEq, Eq, Debug, Serialize, Deserialize)]
pub struct JobProgress {
    pub activity: Activity,
    pub scope: Scope,
    pub remaining: usize,
    pub completed_this_run: usize,
    pub exhausted: usize,
    pub current_title: Option<String>,
    pub started_at: Option<DateTime<Utc>>,
}

impl JobProgress {
    pub fn idle() -> Self {
        Self {
            activity: Activity::Idle,
            scope: Scope::Album,
            remaining: 0,
            completed_this_run: 0,
            exhausted: 0,
            current_title: None,
            started_at: None,
        }
    }

    pub fn is_active(&self) -> bool {
        self.activity != Activity::Idle
    }
}

impl Default for JobProgress {
    fn default() -> Self {
        Self::idle()
    }
}

/// The §2.3 queue query, kept here so the shipped text is the tested text.
/// `:requiredFields` is `Fields::required(Scope::Album).0` (= 3). Ordered so
/// the visible gap — a coverless tile in the grid — is repaired first.
pub const DUE_ALBUMS_SQL: &str = "\
SELECT a.title, a.artist
FROM (
    SELECT albumTitle AS title, artist FROM tracks WHERE albumTitle <> '' GROUP BY 1, 2
) a
LEFT JOIN enrichmentState e
       ON e.scope = 'album'
      AND e.key = flaccy_norm(a.title) || char(31) || flaccy_norm(a.artist)
LEFT JOIN albumInfo i
       ON i.title = a.title AND i.artist = a.artist
WHERE e.key IS NULL
   OR (e.fields & :requiredFields) <> :requiredFields
  AND (
        e.status = 0
     OR e.status = 1
     OR (e.status = 2 AND e.version < :version)
     OR (e.status = 3 AND (e.version < :version OR e.nextEligibleAt IS NULL OR e.nextEligibleAt <= :now))
      )
ORDER BY (i.coverArtData IS NULL) DESC, a.artist, a.title
LIMIT :limit";

/// `count_due` over the same `FROM`/`WHERE` as `DUE_ALBUMS_SQL`; the SQL parity
/// test runs both and asserts they agree on cardinality.
pub const COUNT_DUE_ALBUMS_SQL: &str = "\
SELECT count(*)
FROM (
    SELECT albumTitle AS title, artist FROM tracks WHERE albumTitle <> '' GROUP BY 1, 2
) a
LEFT JOIN enrichmentState e
       ON e.scope = 'album'
      AND e.key = flaccy_norm(a.title) || char(31) || flaccy_norm(a.artist)
WHERE e.key IS NULL
   OR (e.fields & :requiredFields) <> :requiredFields
  AND (
        e.status = 0
     OR e.status = 1
     OR (e.status = 2 AND e.version < :version)
     OR (e.status = 3 AND (e.version < :version OR e.nextEligibleAt IS NULL OR e.nextEligibleAt <= :now))
      )";

/// An AI retitle changes the key, so the renamed album becomes a new pending
/// entity; this runs in the same transaction as the track delete.
pub const ORPHAN_SWEEP_SQL: &str = "\
DELETE FROM enrichmentState
WHERE scope = 'album'
  AND key NOT IN (
      SELECT flaccy_norm(albumTitle) || char(31) || flaccy_norm(artist)
      FROM tracks WHERE albumTitle <> ''
  )";

/// The artist half of the §2.3 predicate: the same WHERE clause over the
/// artists the track table credits, joined on the same normalized key. It lives
/// here rather than in the binary crate so `sql_predicate_agrees_with_is_due`
/// can prove both scopes the Linux client actually runs.
pub const DUE_ARTISTS_SQL: &str = "\
SELECT a.name
FROM (
    SELECT artist AS name FROM tracks WHERE artist <> '' GROUP BY 1
) a
LEFT JOIN enrichmentState e
       ON e.scope = 'artist'
      AND e.key = flaccy_norm(a.name)
WHERE e.key IS NULL
   OR (e.fields & :requiredFields) <> :requiredFields
  AND (
        e.status = 0
     OR e.status = 1
     OR (e.status = 2 AND e.version < :version)
     OR (e.status = 3 AND (e.version < :version OR e.nextEligibleAt IS NULL OR e.nextEligibleAt <= :now))
      )
ORDER BY a.name
LIMIT :limit";

pub const COUNT_DUE_ARTISTS_SQL: &str = "\
SELECT count(*)
FROM (
    SELECT artist AS name FROM tracks WHERE artist <> '' GROUP BY 1
) a
LEFT JOIN enrichmentState e
       ON e.scope = 'artist'
      AND e.key = flaccy_norm(a.name)
WHERE e.key IS NULL
   OR (e.fields & :requiredFields) <> :requiredFields
  AND (
        e.status = 0
     OR e.status = 1
     OR (e.status = 2 AND e.version < :version)
     OR (e.status = 3 AND (e.version < :version OR e.nextEligibleAt IS NULL OR e.nextEligibleAt <= :now))
      )";

/// Seeds stamp `version = 0`, below `current_version`, so legacy `exhausted` and
/// `partial` rows are due once and legacy `satisfied` rows are left alone.
pub const SEED_ALBUM_STATE_SQL: &str = "\
INSERT OR IGNORE INTO enrichmentState
    (scope, key, version, status, fields, attempts, lastAttemptAt, nextEligibleAt, lastFailure)
SELECT 'album',
       flaccy_norm(title) || char(31) || flaccy_norm(artist),
       0,
       CASE WHEN coverArtData IS NOT NULL AND year IS NOT NULL THEN 1 ELSE 0 END,
         (CASE WHEN coverArtData  IS NOT NULL THEN 1  ELSE 0 END)
       + (CASE WHEN year          IS NOT NULL THEN 2  ELSE 0 END)
       + (CASE WHEN genre         IS NOT NULL THEN 4  ELSE 0 END)
       + (CASE WHEN musicBrainzID IS NOT NULL THEN 8  ELSE 0 END),
       0, lastFetched, NULL, NULL
FROM albumInfo";

pub const SEED_ARTIST_STATE_SQL: &str = "\
INSERT OR IGNORE INTO enrichmentState
    (scope, key, version, status, fields, attempts)
SELECT 'artist',
       flaccy_norm(name),
       0,
       CASE WHEN imageURL IS NOT NULL THEN 1 ELSE 0 END,
         (CASE WHEN bio      IS NOT NULL THEN 16 ELSE 0 END)
       + (CASE WHEN imageURL IS NOT NULL THEN 32 ELSE 0 END),
       0
FROM artists";

/// Every user-visible job string, matching the Apple `EnrichmentJobCopy` deck
/// word for word. Number grouping is the one recorded divergence: thin spaces
/// here, a locale-aware formatter on Apple, identical below 1000.
pub mod copy {
    use super::{Activity, Fields, JobProgress, Scope};
    use crate::load_progress::group_digits;

    pub const WAITING_FOR_NETWORK: &str = "Waiting for a connection";
    pub const NEEDS_ENTITLEMENT: &str = "AI cleanup needs Flaccy Lifetime";
    pub const UP_TO_DATE: &str = "Up to date — every album has artwork and a year.";
    pub const FIND_MISSING_ARTWORK: &str = "Find Missing Artwork";
    pub const TRY_AGAIN: &str = "Try Again";
    pub const GAVE_UP_LIST: &str = "Albums Flaccy gave up on";
    pub const OPEN_LIBRARY_SETTINGS: &str = "Open Library Settings";

    pub fn headline(scope: Scope) -> &'static str {
        match scope {
            Scope::Album => "Finding artwork",
            Scope::Artist => "Finding artists",
            Scope::AiBatch => "Identifying albums",
        }
    }

    pub fn detail(remaining: usize) -> String {
        if remaining == 1 {
            "1 left".to_string()
        } else {
            format!("{} left", group_digits(remaining))
        }
    }

    /// The one line a client shows for a running job, or nothing at all — an
    /// unentitled AI pass is reported in Settings, never as launch chrome.
    pub fn ambient(job: &JobProgress) -> Option<String> {
        match job.activity {
            Activity::Idle | Activity::NeedsEntitlement => None,
            Activity::WaitingForNetwork => Some(WAITING_FOR_NETWORK.to_string()),
            Activity::Running => Some(format!(
                "{} · {}",
                headline(job.scope),
                detail(job.remaining)
            )),
        }
    }

    pub fn still_missing(count: usize) -> String {
        format!("{} albums are still missing artwork.", group_digits(count))
    }

    pub fn gave_up(count: usize) -> String {
        format!(
            "Flaccy gave up on {} albums — no source has them.",
            group_digits(count)
        )
    }

    /// What Settings and the report say once the job is asleep, in the order the
    /// reader can act on: what is still queued, then what was given up on, then
    /// the all-clear. Mirrors `EnrichmentJobCopy.settled(remaining:gaveUp:)`.
    pub fn settled(remaining: usize, exhausted: usize) -> String {
        if remaining > 0 {
            still_missing(remaining)
        } else if exhausted > 0 {
            gave_up(exhausted)
        } else {
            UP_TO_DATE.to_string()
        }
    }

    pub fn report_counts(complete: usize, in_progress: usize, gave_up: usize) -> String {
        format!(
            "Complete {} · In progress {} · Gave up {}",
            group_digits(complete),
            group_digits(in_progress),
            group_digits(gave_up)
        )
    }

    /// One exhausted entity, named by the first thing that was never found.
    pub fn report_row(missing: Fields, tries: usize, when: &str) -> String {
        let reason = if !missing.contains(Fields::COVER) {
            "No cover found"
        } else if !missing.contains(Fields::YEAR) {
            "No release date found"
        } else {
            "No artist photo found"
        };
        format!("{reason} · {} tries · {when}", group_digits(tries))
    }

    pub fn accessibility(job: &JobProgress) -> String {
        match job.activity {
            Activity::WaitingForNetwork => {
                format!("{}, waiting for a connection", headline(job.scope))
            }
            _ => format!(
                "{}, {} albums left",
                headline(job.scope),
                group_digits(job.remaining)
            ),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    fn now() -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 8, 21, 12, 0, 0).unwrap()
    }

    fn record(status: Status, fields: Fields) -> EnrichmentRecord {
        EnrichmentRecord {
            status,
            fields,
            ..EnrichmentRecord::new(Scope::Album, "album\u{1F}artist")
        }
    }

    #[test]
    fn nil_record_is_due() {
        assert!(is_due(None, Scope::Album, now()));
        assert!(is_due(None, Scope::Artist, now()));
        assert!(is_due(None, Scope::AiBatch, now()));
    }

    #[test]
    fn satisfied_record_is_never_due() {
        let settled = record(Status::Satisfied, Fields::COVER.union(Fields::YEAR));
        assert!(!is_due(Some(&settled), Scope::Album, now()));
        assert!(!is_due(
            Some(&settled),
            Scope::Album,
            now() + Duration::days(4000)
        ));
    }

    #[test]
    fn exhausted_record_is_never_due_at_the_current_version() {
        let mut dead = record(Status::Exhausted, Fields::COVER);
        dead.version = Scope::Album.current_version();
        assert!(!is_due(Some(&dead), Scope::Album, now()));
        assert!(!is_due(
            Some(&dead),
            Scope::Album,
            now() + Duration::days(4000)
        ));
    }

    #[test]
    fn version_bump_revives_exhausted_and_partial() {
        let mut dead = record(Status::Exhausted, Fields::COVER);
        dead.version = Scope::Album.current_version() - 1;
        assert!(is_due(Some(&dead), Scope::Album, now()));

        let mut waiting = record(Status::Partial, Fields::COVER);
        waiting.version = Scope::Album.current_version() - 1;
        waiting.next_eligible_at = Some(now() + Duration::days(30));
        assert!(is_due(Some(&waiting), Scope::Album, now()));
    }

    #[test]
    fn version_bump_does_not_revive_a_satisfied_record() {
        let mut settled = record(Status::Satisfied, Fields::COVER.union(Fields::YEAR));
        settled.version = Scope::Album.current_version() - 1;
        assert!(!is_due(Some(&settled), Scope::Album, now()));
    }

    #[test]
    fn widening_required_fields_revives_a_satisfied_record() {
        let mut settled = record(Status::Satisfied, Fields::COVER);
        settled.version = Scope::Album.current_version();
        assert!(is_due(Some(&settled), Scope::Album, now()));
    }

    #[test]
    fn partial_is_not_due_before_next_eligible_at() {
        let mut waiting = record(Status::Partial, Fields::COVER);
        waiting.version = Scope::Album.current_version();
        waiting.next_eligible_at = Some(now() + Duration::seconds(1));
        assert!(!is_due(Some(&waiting), Scope::Album, now()));
        assert!(is_due(
            Some(&waiting),
            Scope::Album,
            now() + Duration::seconds(1)
        ));
    }

    #[test]
    fn transport_failure_leaves_attempts_and_schedule_untouched() {
        let mut state = record(Status::Partial, Fields::NONE);
        state.attempts = 2;
        state.last_attempt_at = Some(now() - Duration::days(3));
        apply(
            &mut state,
            Scope::Album,
            Fields::NONE,
            Some(Failure::Transport),
            now(),
        );
        assert_eq!(state.attempts, 2);
        assert_eq!(state.last_attempt_at, Some(now() - Duration::days(3)));
        assert_eq!(state.next_eligible_at, None);
        assert_eq!(state.status, Status::Pending);
        assert!(is_due(Some(&state), Scope::Album, now()));
    }

    #[test]
    fn unauthorized_leaves_the_record_pending_and_unstamped() {
        let mut state = EnrichmentRecord::new(Scope::AiBatch, "/music/unsorted");
        apply(
            &mut state,
            Scope::AiBatch,
            Fields::NONE,
            Some(Failure::Unauthorized),
            now(),
        );
        assert_eq!(state.attempts, 0);
        assert_eq!(state.last_attempt_at, None);
        assert_eq!(state.next_eligible_at, None);
        assert_eq!(state.status, Status::Pending);
        assert!(is_due(Some(&state), Scope::AiBatch, now()));
    }

    #[test]
    fn rate_limited_defers_fifteen_minutes_without_burning_an_attempt() {
        let mut state = record(Status::Pending, Fields::NONE);
        apply(
            &mut state,
            Scope::Album,
            Fields::NONE,
            Some(Failure::RateLimited),
            now(),
        );
        assert_eq!(state.attempts, 0);
        assert_eq!(state.status, Status::Partial);
        assert_eq!(state.next_eligible_at, Some(now() + Duration::minutes(15)));
        assert!(!is_due(Some(&state), Scope::Album, now()));
        assert!(is_due(
            Some(&state),
            Scope::Album,
            now() + Duration::minutes(15)
        ));
    }

    #[test]
    fn not_found_backs_off_one_day_seven_days_thirty_days_then_exhausts() {
        let mut state = record(Status::Pending, Fields::NONE);
        let ladder = [
            Duration::days(1),
            Duration::days(7),
            Duration::days(30),
        ];
        for (index, step) in ladder.iter().enumerate() {
            apply(
                &mut state,
                Scope::Album,
                Fields::NONE,
                Some(Failure::NotFound),
                now(),
            );
            assert_eq!(state.attempts as usize, index + 1);
            assert_eq!(state.status, Status::Partial);
            assert_eq!(state.next_eligible_at, Some(now() + *step));
        }
        apply(
            &mut state,
            Scope::Album,
            Fields::NONE,
            Some(Failure::NotFound),
            now(),
        );
        assert_eq!(state.attempts, 4);
        assert_eq!(state.status, Status::Exhausted);
        assert_eq!(state.next_eligible_at, None);
        assert!(!is_due(Some(&state), Scope::Album, now() + Duration::days(4000)));
    }

    #[test]
    fn cover_and_year_satisfy_an_album_without_genre() {
        let mut state = record(Status::Pending, Fields::NONE);
        apply(
            &mut state,
            Scope::Album,
            Fields::COVER.union(Fields::YEAR),
            None,
            now(),
        );
        assert_eq!(state.status, Status::Satisfied);
        assert!(!state.fields.contains(Fields::GENRE));
        assert!(!is_due(Some(&state), Scope::Album, now()));
    }

    #[test]
    fn partial_resolution_is_persisted_so_a_retry_only_chases_what_is_missing() {
        let mut state = record(Status::Pending, Fields::NONE);
        apply(
            &mut state,
            Scope::Album,
            Fields::COVER,
            Some(Failure::NotFound),
            now(),
        );
        assert!(state.fields.contains(Fields::COVER));
        assert_eq!(state.status, Status::Partial);

        apply(
            &mut state,
            Scope::Album,
            Fields::YEAR,
            None,
            now() + Duration::days(1),
        );
        assert!(state.fields.contains(Fields::COVER.union(Fields::YEAR)));
        assert_eq!(state.status, Status::Satisfied);
    }

    #[test]
    fn album_key_is_case_and_diacritic_normalized() {
        let precomposed = key_album("Homogenic", "Björk");
        let uppercased = key_album("HOMOGENIC", "BJÖRK");
        let decomposed = key_album("Homogenic", "Bjo\u{308}rk");
        assert_eq!(precomposed, uppercased);
        assert_eq!(precomposed, decomposed);
        assert_eq!(precomposed, key_album("  Homogenic  ", " Björk "));
    }

    /// The separator is U+001F precisely because no tag contains it: bare
    /// concatenation collides, and a printable separator collides on titles
    /// that merely look like "title - artist".
    #[test]
    fn album_key_uses_unit_separator_so_title_artist_cannot_collide() {
        let first = key_album("ab", "c");
        let second = key_album("a", "bc");
        assert_ne!(first, second);
        assert_eq!(first, "ab\u{1F}c");
        assert_eq!(second, "a\u{1F}bc");
        assert_ne!(
            key_album("Live - 1975", "Bowie"),
            key_album("Live", "1975 - Bowie")
        );
    }

    #[test]
    fn ai_batch_key_matches_the_directory_grouping() {
        assert_eq!(ai_batch_directory("/music/Jazz/track.flac"), "/music/Jazz");
        assert_eq!(ai_batch_directory("track.flac"), "");
        assert_eq!(ai_batch_directory("/music//track.flac"), "/music");
        assert_eq!(key_ai_batch(ai_batch_directory("track.flac")), "");
        assert_eq!(
            key_ai_batch(ai_batch_directory("/music/Jazz/track.flac")),
            "/music/jazz"
        );
    }

    #[test]
    fn record_round_trips_through_its_columns() {
        let mut state = record(Status::Partial, Fields::COVER.union(Fields::MBID));
        state.attempts = 2;
        state.version = 1;
        state.last_attempt_at = Some(now());
        state.next_eligible_at = Some(now() + Duration::days(7));
        state.last_failure = Some(Failure::NotFound);

        let columns = state.columns();
        let restored = EnrichmentRecord::from_columns(
            columns.scope,
            columns.key.clone(),
            columns.version,
            columns.status,
            columns.fields,
            columns.attempts,
            columns.last_attempt_at.as_deref(),
            columns.next_eligible_at.as_deref(),
            columns.last_failure,
        )
        .expect("columns decode");
        assert_eq!(restored, state);
    }

    /// Exhaustive destructuring is the Rust twin of the Swift `Mirror` check:
    /// adding a fraction to `JobProgress` stops this file compiling.
    #[test]
    fn job_progress_exposes_no_fraction() {
        let JobProgress {
            activity: _,
            scope: _,
            remaining: _,
            completed_this_run: _,
            exhausted: _,
            current_title: _,
            started_at: _,
        } = JobProgress::idle();
        assert!(!JobProgress::idle().is_active());
    }

    #[test]
    fn required_fields_match_the_apple_clients() {
        assert_eq!(Fields::required(Scope::Album).0, 3);
        assert_eq!(Fields::required(Scope::Artist).0, 32);
        assert_eq!(Fields::required(Scope::AiBatch).0, 64);
    }

    #[test]
    fn policy_constants_match_the_apple_clients() {
        assert_eq!(BACKOFF_SECONDS, [86_400, 7 * 86_400, 30 * 86_400]);
        assert_eq!(RATE_LIMIT_DEFERRAL_SECONDS, 15 * 60);
        assert_eq!(TRANSPORT_FAILURES_BEFORE_WAITING, 5);
        assert_eq!(Scope::Album.max_attempts(), 4);
        assert_eq!(Scope::Artist.max_attempts(), 3);
        assert_eq!(Scope::AiBatch.max_attempts(), 3);
    }

    #[test]
    fn composition_table_is_well_formed() {
        let mut seen = std::collections::HashSet::new();
        for (mark, bases, composed) in COMPOSITIONS {
            assert_eq!(
                bases.chars().count(),
                composed.chars().count(),
                "{mark:?} table row"
            );
            assert!(bases.chars().all(|ch| ch.is_lowercase()), "{mark:?} bases");
            let mut unique_bases = std::collections::HashSet::new();
            for base in bases.chars() {
                assert!(unique_bases.insert(base), "{mark:?} repeats base {base:?}");
            }
            for pair in composed.chars() {
                assert!(!pair.is_ascii(), "{mark:?} composes to bare {pair:?}");
                assert!(pair.is_lowercase(), "{mark:?} composes to {pair:?}");
                assert!(seen.insert(pair), "{pair:?} is produced by two different marks");
            }
        }
    }

    /// Every row of [`COMPOSITIONS`], checked against an oracle rather than
    /// against itself: the expected strings below are what Foundation's
    /// `precomposedStringWithCanonicalMapping` produces, so a row that is
    /// internally consistent but not what the Apple clients key with still
    /// fails. `EnrichmentJobTests.testCompositionCorpusMatchesFoundationNFC`
    /// pins the same corpus on the Swift side.
    #[test]
    fn every_composition_row_matches_foundation_nfc() {
        let expected: &[(char, &str, &str)] = &[
            ('\u{0300}', "aeinouy", "àèìǹòùỳ"),
            ('\u{0301}', "aceginorsuyz", "áćéǵíńóŕśúýź"),
            ('\u{0302}', "aceghijosuwy", "âĉêĝĥîĵôŝûŵŷ"),
            ('\u{0303}', "aeinou", "ãẽĩñõũ"),
            ('\u{0304}', "aeiou", "āēīōū"),
            ('\u{0306}', "aegiou", "ăĕğĭŏŭ"),
            ('\u{0307}', "cegz", "ċėġż"),
            ('\u{0308}', "aeiouy", "äëïöüÿ"),
            ('\u{0309}', "aeiouy", "ảẻỉỏủỷ"),
            ('\u{030a}', "au", "åů"),
            ('\u{030b}', "ou", "őű"),
            ('\u{030c}', "cdeghlnrstz", "čďěǧȟľňřšťž"),
            ('\u{0323}', "aeiouy", "ạẹịọụỵ"),
            ('\u{0327}', "cgklnrst", "çģķļņŗşţ"),
            ('\u{0328}', "aeiou", "ąęįǫų"),
        ];
        assert_eq!(expected.len(), COMPOSITIONS.len());
        for (mark, bases, composed) in expected {
            let decomposed: String = bases.chars().flat_map(|base| [base, *mark]).collect();
            assert_eq!(&normalize(&decomposed), composed, "{mark:?} row");
            assert_eq!(
                &normalize(composed),
                composed,
                "{mark:?} row already composed"
            );
        }
    }

    #[test]
    fn caron_and_acute_keys_agree_between_nfc_and_nfd() {
        for (nfc, nfd) in [
            ("Ľubomír", "L\u{030c}ubomi\u{0301}r"),
            ("Hana Hegerová", "Hana Hegerova\u{0301}"),
            ("Ťažký", "T\u{030c}az\u{030c}ky\u{0301}"),
            ("Ǵ", "G\u{0301}"),
            ("Ȟ", "H\u{030c}"),
        ] {
            assert_eq!(key_artist(nfc), key_artist(nfd), "{nfc}");
        }
    }

    #[test]
    fn ambient_line_reads_as_a_countdown() {
        let mut job = JobProgress::idle();
        job.activity = Activity::Running;
        job.remaining = 12;
        assert_eq!(
            copy::ambient(&job).as_deref(),
            Some("Finding artwork · 12 left")
        );
        job.remaining = 1;
        assert_eq!(
            copy::ambient(&job).as_deref(),
            Some("Finding artwork · 1 left")
        );
        job.activity = Activity::WaitingForNetwork;
        assert_eq!(
            copy::ambient(&job).as_deref(),
            Some("Waiting for a connection")
        );
        job.activity = Activity::NeedsEntitlement;
        assert_eq!(copy::ambient(&job), None);
    }

    #[test]
    fn settled_reads_in_the_order_a_reader_can_act_on() {
        assert_eq!(copy::settled(40, 3), copy::still_missing(40));
        assert_eq!(copy::settled(0, 3), copy::gave_up(3));
        assert_eq!(copy::settled(0, 0), copy::UP_TO_DATE);
        assert_eq!(copy::settled(1, 0), copy::still_missing(1));
    }

    mod sql {
        use super::*;
        use rusqlite::{named_params, Connection};

        /// The registration `Db::open` performs, repeated here so the statements
        /// under test run against the connection shape they ship on. The body is
        /// the shared [`normalize`], so the two sites cannot disagree about what
        /// a key is — only about whether the function exists at all, which every
        /// statement below would fail loudly on.
        fn register_normalizer(conn: &Connection) {
            conn.create_scalar_function(
                NORM_FN,
                1,
                rusqlite::functions::FunctionFlags::SQLITE_UTF8
                    | rusqlite::functions::FunctionFlags::SQLITE_DETERMINISTIC
                    | rusqlite::functions::FunctionFlags::SQLITE_INNOCUOUS,
                |ctx| Ok(normalize(ctx.get_raw(0).as_str()?)),
            )
            .expect("flaccy_norm");
        }

        fn schema(conn: &Connection) {
            register_normalizer(conn);
            conn.execute_batch(
                "CREATE TABLE tracks (
                     fileURL TEXT PRIMARY KEY,
                     albumTitle TEXT NOT NULL,
                     artist TEXT NOT NULL,
                     aiAnalyzed INTEGER NOT NULL DEFAULT 0
                 );
                 CREATE TABLE albumInfo (
                     title TEXT NOT NULL,
                     artist TEXT NOT NULL,
                     coverArtData BLOB,
                     coverArtURL TEXT,
                     year TEXT,
                     genre TEXT,
                     musicBrainzID TEXT,
                     lastFetched DATETIME,
                     PRIMARY KEY (title, artist)
                 );
                 CREATE TABLE artists (
                     name TEXT PRIMARY KEY,
                     bio TEXT,
                     imageURL TEXT
                 );
                 CREATE TABLE enrichmentState (
                     scope TEXT NOT NULL,
                     key TEXT NOT NULL,
                     version INTEGER NOT NULL DEFAULT 0,
                     status INTEGER NOT NULL DEFAULT 0,
                     fields INTEGER NOT NULL DEFAULT 0,
                     attempts INTEGER NOT NULL DEFAULT 0,
                     lastAttemptAt DATETIME,
                     nextEligibleAt DATETIME,
                     lastFailure TEXT,
                     PRIMARY KEY (scope, key)
                 ) WITHOUT ROWID;
                 CREATE INDEX enrichmentState_on_due
                     ON enrichmentState(scope, status, nextEligibleAt);",
            )
            .expect("schema");
        }

        /// 36 seeded rows covering every status × schedule × field mask, plus
        /// four albums with no state row at all — the "never attempted" case
        /// the `e.key IS NULL` arm exists for.
        fn seed_matrix(conn: &Connection, at: DateTime<Utc>) -> Vec<(String, Option<EnrichmentRecord>)> {
            let statuses = [
                Status::Pending,
                Status::Satisfied,
                Status::Exhausted,
                Status::Partial,
            ];
            let masks = [Fields::NONE, Fields::COVER, Fields::COVER.union(Fields::YEAR)];
            let schedules = [
                None,
                Some(at - Duration::days(1)),
                Some(at + Duration::days(1)),
            ];
            let mut expectations = Vec::new();
            let mut index = 0;
            for status in statuses {
                for mask in masks {
                    for schedule in schedules {
                        let title = spelling(index);
                        let artist = credited(index);
                        insert_track(conn, index, &title, &artist);
                        let mut state = EnrichmentRecord::new(Scope::Album, key_album(&title, &artist));
                        state.status = status;
                        state.fields = mask;
                        state.version = (index % 2) as i64;
                        state.next_eligible_at = schedule;
                        insert_state(conn, &state);
                        expectations.push((key_album(&title, &artist), Some(state)));
                        index += 1;
                    }
                }
            }
            for offset in 0..4 {
                let title = format!("Unseeded {offset}");
                let artist = "Nobödy".to_string();
                insert_track(conn, index, &title, &artist);
                expectations.push((key_album(&title, &artist), None));
                index += 1;
            }
            expectations
        }

        /// Album titles as real tag data spells them: padded with plain spaces,
        /// carrying an uppercase letter SQLite's ASCII-only `lower()` refuses to
        /// fold, decomposed the way an APFS-derived path arrives, and padded with
        /// a tab `trim()` leaves behind.
        fn spelling(index: usize) -> String {
            match index % 4 {
                0 => format!("  Album {index} "),
                1 => format!("Ágætis byrjun {index}"),
                2 => format!("Bjo\u{308}rk Album {index}"),
                _ => format!("\tMOTÖRHEAD {index} \t"),
            }
        }

        /// The same four spellings on the artist half of the key, so a mismatch
        /// on either side of the unit separator fails the parity test.
        fn credited(index: usize) -> String {
            match index % 3 {
                0 => format!("Artist {}", index % 7),
                1 => format!("Sigur Rós {}", index % 7),
                _ => format!(" Sigur Ro\u{301}s {} \t", index % 7),
            }
        }

        fn insert_track(conn: &Connection, index: usize, title: &str, artist: &str) {
            conn.execute(
                "INSERT INTO tracks (fileURL, albumTitle, artist) VALUES (?1, ?2, ?3)",
                rusqlite::params![format!("/music/{index}.flac"), title, artist],
            )
            .expect("track");
        }

        fn insert_state(conn: &Connection, state: &EnrichmentRecord) {
            let columns = state.columns();
            conn.execute(
                "INSERT INTO enrichmentState
                     (scope, key, version, status, fields, attempts, lastAttemptAt, nextEligibleAt, lastFailure)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
                rusqlite::params![
                    columns.scope,
                    columns.key,
                    columns.version,
                    columns.status,
                    columns.fields,
                    columns.attempts,
                    columns.last_attempt_at,
                    columns.next_eligible_at,
                    columns.last_failure,
                ],
            )
            .expect("state");
        }

        #[test]
        fn sql_predicate_agrees_with_is_due() {
            let conn = Connection::open_in_memory().expect("memory db");
            schema(&conn);
            let at = now();
            let expectations = seed_matrix(&conn, at);
            assert_eq!(expectations.len(), 40);

            let expected: std::collections::BTreeSet<String> = expectations
                .iter()
                .filter(|(_, state)| is_due(state.as_ref(), Scope::Album, at))
                .map(|(key, _)| key.clone())
                .collect();

            let mut statement = conn.prepare(DUE_ALBUMS_SQL).expect("prepare");
            let rows = statement
                .query_map(
                    named_params! {
                        ":requiredFields": Fields::required(Scope::Album).0,
                        ":version": Scope::Album.current_version(),
                        ":now": encode_timestamp(at),
                        ":limit": 1000i64,
                    },
                    |row| {
                        let title: String = row.get(0)?;
                        let artist: String = row.get(1)?;
                        Ok(key_album(&title, &artist))
                    },
                )
                .expect("query")
                .collect::<Result<std::collections::BTreeSet<String>, _>>()
                .expect("rows");

            assert_eq!(rows, expected);
            assert!(!expected.is_empty());
            assert!(expected.len() < expectations.len());

            let counted: i64 = conn
                .query_row(
                    COUNT_DUE_ALBUMS_SQL,
                    named_params! {
                        ":requiredFields": Fields::required(Scope::Album).0,
                        ":version": Scope::Album.current_version(),
                        ":now": encode_timestamp(at),
                    },
                    |row| row.get(0),
                )
                .expect("count");
            assert_eq!(counted as usize, expected.len());
        }

        #[test]
        fn orphan_sweep_drops_state_for_albums_that_left() {
            let conn = Connection::open_in_memory().expect("memory db");
            schema(&conn);
            let at = now();
            seed_matrix(&conn, at);
            let survivors: std::collections::BTreeSet<String> = (0..4)
                .map(|index| key_album(&spelling(index), &credited(index)))
                .collect();
            assert_eq!(survivors.len(), 4);

            conn.execute(
                "DELETE FROM tracks WHERE fileURL NOT IN
                     ('/music/0.flac', '/music/1.flac', '/music/2.flac', '/music/3.flac')",
                [],
            )
            .expect("delete tracks");
            conn.execute(ORPHAN_SWEEP_SQL, []).expect("sweep");

            let remaining: std::collections::BTreeSet<String> = conn
                .prepare("SELECT key FROM enrichmentState WHERE scope = 'album'")
                .expect("prepare")
                .query_map([], |row| row.get(0))
                .expect("query")
                .collect::<Result<_, _>>()
                .expect("rows");
            assert_eq!(remaining, survivors);
        }

        /// The defect this whole registration exists to prevent: an album whose
        /// title carries an uppercase non-ASCII letter is written by the app,
        /// swept by SQL, and counted by SQL — and all three have to agree, or
        /// every scan deletes the state and re-enriches the library from zero.
        #[test]
        fn a_non_ascii_album_survives_the_sweep_and_reports_settled() {
            let conn = Connection::open_in_memory().expect("memory db");
            schema(&conn);
            let at = now();
            let title = "Ágætis byrjun";
            let artist = "Sigur Rós";
            insert_track(&conn, 0, title, artist);
            let mut state = EnrichmentRecord::new(Scope::Album, key_album(title, artist));
            state.version = Scope::Album.current_version();
            state.status = Status::Satisfied;
            state.fields = Fields::required(Scope::Album);
            insert_state(&conn, &state);

            conn.execute(ORPHAN_SWEEP_SQL, []).expect("sweep");
            let surviving: i64 = conn
                .query_row(
                    "SELECT count(*) FROM enrichmentState WHERE scope = 'album' AND key = ?1",
                    rusqlite::params![key_album(title, artist)],
                    |row| row.get(0),
                )
                .expect("count");
            assert_eq!(surviving, 1);

            let due: i64 = conn
                .query_row(
                    COUNT_DUE_ALBUMS_SQL,
                    named_params! {
                        ":requiredFields": Fields::required(Scope::Album).0,
                        ":version": Scope::Album.current_version(),
                        ":now": encode_timestamp(at),
                    },
                    |row| row.get(0),
                )
                .expect("count due");
            assert_eq!(due, 0);
        }

        #[test]
        fn sql_normalizer_agrees_with_the_rust_one() {
            let conn = Connection::open_in_memory().expect("memory db");
            register_normalizer(&conn);
            for value in [
                "  Album 0 ",
                "Ágætis byrjun",
                "Bjo\u{308}rk",
                "\tMOTÖRHEAD \t",
                "ÓLAFUR ARNALDS",
                "L\u{030c}ubomír",
                "",
                "  ",
            ] {
                let through_sql: String = conn
                    .query_row("SELECT flaccy_norm(?1)", rusqlite::params![value], |row| {
                        row.get(0)
                    })
                    .expect("flaccy_norm");
                assert_eq!(through_sql, normalize(value), "{value:?}");
            }
        }

        #[test]
        fn sql_artist_predicate_agrees_with_is_due() {
            let conn = Connection::open_in_memory().expect("memory db");
            schema(&conn);
            let at = now();
            let statuses = [
                Status::Pending,
                Status::Satisfied,
                Status::Exhausted,
                Status::Partial,
            ];
            let masks = [Fields::NONE, Fields::ARTIST_BIO, Fields::ARTIST_IMAGE];
            let schedules = [
                None,
                Some(at - Duration::days(1)),
                Some(at + Duration::days(1)),
            ];
            let mut expectations: Vec<(String, Option<EnrichmentRecord>)> = Vec::new();
            let mut index = 0;
            for status in statuses {
                for mask in masks {
                    for schedule in schedules {
                        let name = format!("{} {index}", credited(index));
                        insert_track(&conn, index, "Album", &name);
                        let mut state = EnrichmentRecord::new(Scope::Artist, key_artist(&name));
                        state.status = status;
                        state.fields = mask;
                        state.version = (index % 2) as i64;
                        state.next_eligible_at = schedule;
                        insert_state(&conn, &state);
                        expectations.push((key_artist(&name), Some(state)));
                        index += 1;
                    }
                }
            }
            for offset in 0..4 {
                let name = format!("Unseeded Ártist {offset}");
                insert_track(&conn, index, "Album", &name);
                expectations.push((key_artist(&name), None));
                index += 1;
            }

            let expected: std::collections::BTreeSet<String> = expectations
                .iter()
                .filter(|(_, state)| is_due(state.as_ref(), Scope::Artist, at))
                .map(|(key, _)| key.clone())
                .collect();

            let mut statement = conn.prepare(DUE_ARTISTS_SQL).expect("prepare");
            let rows = statement
                .query_map(
                    named_params! {
                        ":requiredFields": Fields::required(Scope::Artist).0,
                        ":version": Scope::Artist.current_version(),
                        ":now": encode_timestamp(at),
                        ":limit": 1000i64,
                    },
                    |row| Ok(key_artist(&row.get::<_, String>(0)?)),
                )
                .expect("query")
                .collect::<Result<std::collections::BTreeSet<String>, _>>()
                .expect("rows");
            assert_eq!(rows, expected);
            assert!(!expected.is_empty());
            assert!(expected.len() < expectations.len());

            let counted: i64 = conn
                .query_row(
                    COUNT_DUE_ARTISTS_SQL,
                    named_params! {
                        ":requiredFields": Fields::required(Scope::Artist).0,
                        ":version": Scope::Artist.current_version(),
                        ":now": encode_timestamp(at),
                    },
                    |row| row.get(0),
                )
                .expect("count");
            assert_eq!(counted as usize, expected.len());
        }

        #[test]
        fn seed_classifies_legacy_rows_exactly_once() {
            let conn = Connection::open_in_memory().expect("memory db");
            schema(&conn);
            conn.execute(
                "INSERT INTO albumInfo (title, artist, coverArtData, year, genre, musicBrainzID, lastFetched)
                 VALUES ('Kind of Blue', 'Miles Davis', x'00', '1959', 'Jazz', 'mbid-1', '2026-01-01T00:00:00Z'),
                        ('  Homogenic ', 'Bjork', NULL, NULL, NULL, NULL, NULL),
                        ('Ágætis byrjun', 'Sigur Rós', x'00', '1999', NULL, NULL, NULL),
                        ('Blue', 'Joni Mitchell', x'00', NULL, NULL, NULL, NULL)",
                [],
            )
            .expect("albumInfo");
            conn.execute(
                "INSERT INTO artists (name, bio, imageURL)
                 VALUES ('Miles Davis', 'bio', 'https://example.invalid/miles.jpg'),
                        ('SIGUR RÓS', NULL, NULL),
                        ('  Bjork ', NULL, NULL)",
                [],
            )
            .expect("artists");

            let snapshot = |conn: &Connection| -> Vec<(String, String, i64, i64, i64)> {
                conn.prepare(
                    "SELECT scope, key, version, status, fields FROM enrichmentState
                     ORDER BY scope, key",
                )
                .expect("prepare")
                .query_map([], |row| {
                    Ok((
                        row.get(0)?,
                        row.get(1)?,
                        row.get(2)?,
                        row.get(3)?,
                        row.get(4)?,
                    ))
                })
                .expect("query")
                .collect::<Result<_, _>>()
                .expect("rows")
            };

            conn.execute(SEED_ALBUM_STATE_SQL, []).expect("album seed");
            conn.execute(SEED_ARTIST_STATE_SQL, []).expect("artist seed");
            let first = snapshot(&conn);

            conn.execute(SEED_ALBUM_STATE_SQL, []).expect("album reseed");
            conn.execute(SEED_ARTIST_STATE_SQL, []).expect("artist reseed");
            let second = snapshot(&conn);

            assert_eq!(first, second);
            assert_eq!(first.len(), 7);

            let album_of = |key: &str| -> (i64, i64, i64) {
                let row = first
                    .iter()
                    .find(|(scope, candidate, _, _, _)| scope == "album" && candidate == key)
                    .unwrap_or_else(|| panic!("missing {key}"));
                (row.2, row.3, row.4)
            };
            assert_eq!(album_of(&key_album("Kind of Blue", "Miles Davis")), (0, 1, 15));
            assert_eq!(album_of(&key_album("  Homogenic ", "Bjork")), (0, 0, 0));
            assert_eq!(album_of(&key_album("Blue", "Joni Mitchell")), (0, 0, 1));
            assert_eq!(
                album_of(&key_album("Ágætis byrjun", "Sigur Rós")),
                (0, 1, 3)
            );

            let artist_of = |key: &str| -> (i64, i64, i64) {
                let row = first
                    .iter()
                    .find(|(scope, candidate, _, _, _)| scope == "artist" && candidate == key)
                    .unwrap_or_else(|| panic!("missing {key}"));
                (row.2, row.3, row.4)
            };
            assert_eq!(artist_of(&key_artist("Miles Davis")), (0, 1, 48));
            assert_eq!(artist_of(&key_artist("SIGUR RÓS")), (0, 0, 0));
            assert_eq!(artist_of(&key_artist("  Bjork ")), (0, 0, 0));
        }
    }
}
