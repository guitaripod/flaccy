//! Last.fm history sync and scrobble relay against an in-process fake Last.fm and fake signer.

mod common;
#[path = "lastfm_fake/mod.rs"]
mod fake;

use std::io::Cursor;
use std::os::unix::fs::PermissionsExt;
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::{Arc, Once};
use std::time::Duration;

use flaccy_library::listen_history::SETTLE_INTERVAL_SECONDS;
use flaccy_library::server_sync::song_key_of;
use flaccy_server::config::Config;
use flaccy_server::dbthread::Durability;
use flaccy_server::lastfm::status::{gather, problems, report};
use flaccy_server::lastfm::{Desk, HistoryWorker, LastfmApi, LastfmSettings, Pacing, RelayPass, RelayWorker, ACCOUNT_KEY};
use flaccy_server::security::{self, Role, User, UserId};
use flaccy_server::state::AppState;
use flaccy_server::sync::{self, ServerListen};
use flaccy_server_core::model::{SongRef, Source};
use flaccy_server_core::mutation::ListenInput;
use flaccy_server_core::song::event_id_rec;
use serde_json::json;

use common::TempDir;
use fake::{plays, Fake, Play, ScrobbleReply, ACCOUNT, API_KEY, SESSION_KEY};

const NOW_S: i64 = 1_790_000_000;
const PAGE: usize = 200;
static LOGGER: Once = Once::new();
static LOG_DIR: std::sync::OnceLock<TempDir> = std::sync::OnceLock::new();

struct Rig {
    dir: TempDir,
    clock: Arc<AtomicI64>,
    security: security::Store,
    sync: sync::Store,
    user: User,
    fake: Fake,
    api: Arc<LastfmApi>,
}

impl Rig {
    async fn new(history: Vec<Play>) -> Self {
        LOGGER.call_once(|| {
            let dir = LOG_DIR.get_or_init(|| TempDir::new("lastfm-log"));
            flaccy_library::logger::init(dir.path());
        });
        let dir = TempDir::new("lastfm");
        let clock = Arc::new(AtomicI64::new(NOW_S * 1000));
        let reading = clock.clone();
        let clock_fn: security::Clock = Arc::new(move || reading.load(Ordering::SeqCst));
        let security = security::Store::open(&dir.file("security.sqlite")).await.unwrap();
        let incarnation = security.incarnation().await.unwrap();
        let sync = sync::Store::open_with(&dir.file("state.sqlite"), incarnation, clock_fn, Durability::Normal).await.unwrap();
        let user = security.create_user("alice", Role::Member).await.unwrap();
        let fake = Fake::start(history).await;
        let settings = LastfmSettings {
            lastfm_api_key: Some(API_KEY.to_owned()),
            lastfm_api_url: Some(fake.api_url()),
            lastfm_sign_url: Some(fake.sign_url()),
        };
        let device = security.server_id().await.unwrap();
        let api = Arc::new(LastfmApi::new(settings.endpoints(), API_KEY.to_owned(), device));
        Self { dir, clock, security, sync, user, fake, api }
    }

    fn advance(&self, seconds: i64) {
        self.clock.fetch_add(seconds * 1000, Ordering::SeqCst);
    }

    fn now(&self) -> i64 {
        self.clock.load(Ordering::SeqCst) / 1000
    }

    fn history(&self) -> HistoryWorker {
        HistoryWorker::new(self.sync.clone(), self.api.clone(), Pacing::instant())
    }

    fn relay(&self) -> RelayWorker {
        RelayWorker::new(self.sync.clone(), self.security.clone(), self.api.clone(), Pacing::instant())
    }

    fn desk(&self) -> Desk {
        Desk { security: self.security.clone(), sync: self.sync.clone() }
    }

    async fn set_account(&self) {
        self.sync.set_scalar_as_server(&self.user.id, ACCOUNT_KEY, json!(ACCOUNT)).await.unwrap();
    }

    async fn connect(&self) -> Vec<String> {
        let mut lines = Vec::new();
        let mut input = Cursor::new(b"\n".to_vec());
        self.desk().connect(&self.api, "alice", &mut input, &mut |text: &str| lines.push(text.to_owned())).await.unwrap();
        lines
    }

    async fn listens(&self) -> i64 {
        self.sync.stats().await.unwrap().listens
    }

    async fn relay_pass(&self) -> RelayPass {
        self.relay().relay_user(&self.user.id).await.unwrap()
    }

    async fn record(&self, source: Source, index: usize, ts: i64) {
        let listen = ServerListen { source, input: listen_input(index, ts) };
        self.sync.record_listens_as_server(&self.user.id, vec![listen]).await.unwrap();
    }
}

fn song_ref(index: usize) -> SongRef {
    let (title, artist) = (format!("Played {index}"), format!("Player {index}"));
    SongRef { song_key: song_key_of(&title, &artist), title, artist, album: "Record".into(), duration_ms: 200_000, ..SongRef::default() }
}

fn listen_input(index: usize, ts: i64) -> ListenInput {
    ListenInput { event_id: event_id_rec("third-party", "i", index as u64), ts, song: song_ref(index), played_s: 200, recorded: true }
}

fn assert_secrets_absent(text: &str) {
    for secret in [API_KEY, SESSION_KEY] {
        assert!(!text.contains(secret), "a key reached the output");
    }
}

fn assert_logs_clean() {
    let Some(dir) = LOG_DIR.get() else { return };
    let log = std::fs::read_to_string(dir.file("flaccy.log")).unwrap_or_default();
    assert!(!log.is_empty(), "the test logger wrote nothing");
    assert_secrets_absent(&log);
}

#[tokio::test(flavor = "multi_thread")]
async fn five_thousand_plays_backfill_across_pages_and_resume_after_a_crash() {
    let rig = Rig::new(plays(5_000, NOW_S - 3_600, 600)).await;
    rig.set_account().await;
    assert_eq!(rig.sync.lastfm_accounts().await.unwrap(), vec![(rig.user.id.clone(), ACCOUNT.to_owned())]);
    rig.fake.inner.hang_page.store(12, Ordering::SeqCst);
    let first = rig.history();
    let (user, account) = (rig.user.id.clone(), ACCOUNT.to_owned());
    let crashed = tokio::spawn(async move { first.sync_user(&user, &account).await });
    while rig.fake.inner.hung.load(Ordering::SeqCst) == 0 {
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    crashed.abort();
    rig.fake.inner.hang_page.store(0, Ordering::SeqCst);
    rig.fake.inner.release.notify_waiters();

    let saved = rig.sync.lastfm_sync_record(&rig.user.id).await.unwrap().unwrap();
    assert_eq!((saved.plan.backfill_page, saved.stored), (12, 11 * PAGE as i64));
    assert!(!saved.plan.backfill_complete && saved.plan.backfill_anchor.is_some());
    assert_eq!(rig.listens().await, 11 * PAGE as i64);

    let page_twelve: Vec<ServerListen> = rig.fake.inner.plays.lock().unwrap()[11 * PAGE..12 * PAGE]
        .iter()
        .map(pulled_listen)
        .collect();
    rig.sync.record_listens_as_server(&rig.user.id, page_twelve).await.unwrap();
    let reads_before = rig.fake.reads().len();

    rig.history().sync_user(&rig.user.id, ACCOUNT).await.unwrap();
    let resumed = rig.fake.reads()[reads_before..].to_vec();
    assert_eq!(resumed[0].page, 12, "the resumed run starts at the saved page, not page 1");
    assert_eq!(resumed[0].to, Some(saved.plan.backfill_anchor.unwrap()));
    assert_eq!(rig.listens().await, 5_000, "no play is missing or doubled");
    let done = rig.sync.lastfm_sync_record(&rig.user.id).await.unwrap().unwrap();
    assert!(done.plan.backfill_complete && done.total_pages == 25 && done.last_error.is_none());
    assert!(rig.sync.lastfm_history_flowing(&rig.user.id).await.unwrap());
    assert!(rig.fake.reads().iter().all(|read| read.page >= 1), "pages are 1-based");
    assert_logs_clean();
}

fn pulled_listen(play: &Play) -> ServerListen {
    let song_key = song_key_of(&play.title, &play.artist);
    ServerListen {
        source: Source::Lastfm,
        input: ListenInput {
            event_id: flaccy_server_core::song::event_id_lfm(ACCOUNT, play.uts, &song_key),
            ts: play.uts,
            song: SongRef { song_key, title: play.title.clone(), artist: play.artist.clone(), album: play.album.clone(), ..SongRef::default() },
            played_s: 0,
            recorded: false,
        },
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn catch_ups_start_an_hour_before_the_newest_play_and_the_settle_reaches_back_fourteen_days() {
    let rig = Rig::new(plays(450, NOW_S - 600, 3_000)).await;
    rig.history().sync_user(&rig.user.id, ACCOUNT).await.unwrap();
    let after_backfill = rig.listens().await;
    assert_eq!(after_backfill, 450);
    let settle = rig.fake.reads().last().cloned().unwrap();
    assert_eq!((settle.from, settle.to), (Some(NOW_S - 14 * 86_400), None), "the first pull after the backfill is the settle");

    rig.advance(1_800);
    rig.fake.add_play(Play { uts: NOW_S + 900, title: "Fresh".into(), artist: "New".into(), album: "".into() });
    rig.history().sync_user(&rig.user.id, ACCOUNT).await.unwrap();
    let catch_up = rig.fake.reads().last().cloned().unwrap();
    assert_eq!(catch_up.from, Some(NOW_S - 3_600), "a catch-up reads from the newest time the backfill reached, minus one hour");
    assert_eq!(rig.listens().await, after_backfill + 1);

    rig.history().sync_user(&rig.user.id, ACCOUNT).await.unwrap();
    let overlap = rig.fake.reads().last().cloned().unwrap();
    assert_eq!(overlap.from, Some(NOW_S + 900 - 3_600), "the next catch-up starts an hour before the newest play it stored");
    assert_eq!(rig.listens().await, after_backfill + 1, "pulling the overlap again stores nothing");

    let late = Play { uts: rig.now() - 5 * 86_400, title: "Late".into(), artist: "Straggler".into(), album: "".into() };
    rig.fake.add_play(late);
    rig.history().sync_user(&rig.user.id, ACCOUNT).await.unwrap();
    assert_eq!(rig.listens().await, after_backfill + 1, "a catch-up does not look back far enough for a late scrobble");

    rig.advance(SETTLE_INTERVAL_SECONDS + 60);
    rig.history().sync_user(&rig.user.id, ACCOUNT).await.unwrap();
    let settled = rig.fake.reads().last().cloned().unwrap();
    assert_eq!(settled.from, Some(rig.now() - 14 * 86_400));
    assert_eq!(rig.listens().await, after_backfill + 2, "the daily settle picks the late scrobble up");
    assert_logs_clean();
}

#[tokio::test(flavor = "multi_thread")]
async fn history_survives_server_errors_with_doubling_waits_and_a_permanent_failure_is_recorded() {
    let rig = Rig::new(plays(30, NOW_S - 600, 600)).await;
    rig.fake.inner.fail_reads.store(2, Ordering::SeqCst);
    rig.history().sync_user(&rig.user.id, ACCOUNT).await.unwrap();
    assert_eq!(rig.listens().await, 30);
    assert!(rig.fake.reads().len() >= 4, "the first page took three attempts");

    let broken = Rig::new(plays(5, NOW_S - 600, 600)).await;
    broken.fake.inner.fail_reads.store(1_000, Ordering::SeqCst);
    assert!(broken.history().sync_user(&broken.user.id, ACCOUNT).await.is_err());
    let record = broken.sync.lastfm_sync_record(&broken.user.id).await.unwrap().unwrap();
    assert!(record.last_error.is_some() && record.retry_at.unwrap() > broken.now());
    assert_eq!(broken.fake.reads().len(), 5, "five attempts, then the sync gives up until its retry time");
    assert_eq!(broken.history().sync_due_users().await, 0, "no account is set, so nothing is due");
    assert_logs_clean();
}

#[tokio::test(flavor = "multi_thread")]
async fn the_relay_submits_an_opensubsonic_play_once_and_never_the_other_sources() {
    let rig = Rig::new(Vec::new()).await;
    rig.record(Source::Opensubsonic, 1, NOW_S - 500).await;
    let lines = rig.connect().await;
    assert!(lines.iter().any(|line| line.contains("token") && line.contains("last.fm/api/auth")), "the authorisation page is shown");
    let mode = std::fs::metadata(rig.dir.file("security.sqlite")).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode, 0o600);
    let session = rig.security.lastfm_session(&rig.user.id).await.unwrap().unwrap();
    assert_eq!((session.username.as_str(), session.session_key.as_str()), (ACCOUNT, SESSION_KEY));

    rig.record(Source::Opensubsonic, 2, NOW_S - 400).await;
    rig.record(Source::Flaccy, 3, NOW_S - 300).await;
    rig.record(Source::Lastfm, 4, NOW_S - 200).await;
    rig.record(Source::Migrated, 5, NOW_S - 100).await;
    assert_eq!(rig.relay_pass().await.submitted, 1);
    assert_eq!(rig.relay_pass().await.submitted, 0, "a play goes out once");
    let batches = rig.fake.batches();
    assert_eq!(batches.len(), 1);
    assert_eq!(batches[0].iter().map(|play| play.title.as_str()).collect::<Vec<_>>(), vec!["Played 2"]);
    assert_eq!(batches[0][0].timestamp, NOW_S - 400);

    let device = rig.security.server_id().await.unwrap();
    let signed = rig.fake.inner.signed.lock().unwrap().clone();
    assert!(signed.iter().all(|(_, id)| *id == device), "the signer sees the server id");
    let methods: Vec<&str> = signed.iter().map(|(method, _)| method.as_str()).collect();
    assert_eq!(methods, vec!["auth.getToken", "auth.getSession", "track.scrobble"]);

    rig.relay().update_now_playing(&rig.user.id, flaccy_server::lastfm::ScrobbleEntry { title: "Right Now".into(), artist: "Live".into(), album: "".into(), timestamp: 0, duration_s: 100 }).await;
    assert_eq!(rig.fake.inner.now_playing.lock().unwrap().clone(), vec!["Right Now".to_owned()]);

    let statuses = gather(&rig.sync, &rig.security).await.unwrap();
    let text = serde_json::to_string(&report(&statuses, true)).unwrap();
    assert_secrets_absent(&text);
    assert!(text.contains("\"submitted\":1"));
    assert_logs_clean();
}

#[tokio::test(flavor = "multi_thread")]
async fn a_server_error_is_retried_after_its_wait_and_a_duplicate_answer_counts_as_done() {
    let rig = Rig::new(Vec::new()).await;
    rig.connect().await;
    rig.record(Source::Opensubsonic, 1, NOW_S - 50).await;
    rig.fake.script(&[ScrobbleReply::ServerError]);
    let failed = rig.relay_pass().await;
    assert_eq!((failed.submitted, failed.deferred), (0, 1));
    assert_eq!(rig.sync.lastfm_queue_len(&rig.user.id).await.unwrap(), 1);
    let calls = rig.fake.inner.scrobble_calls.load(Ordering::SeqCst);
    assert_eq!(rig.relay_pass().await, RelayPass::default(), "the play waits out its backoff");
    assert_eq!(rig.fake.inner.scrobble_calls.load(Ordering::SeqCst), calls);

    rig.advance(2);
    assert_eq!(rig.relay_pass().await.submitted, 1);
    assert_eq!(rig.sync.lastfm_queue_len(&rig.user.id).await.unwrap(), 0);

    rig.record(Source::Opensubsonic, 2, NOW_S - 40).await;
    rig.fake.script(&[ScrobbleReply::Duplicate]);
    let duplicate = rig.relay_pass().await;
    assert_eq!((duplicate.submitted, duplicate.deferred), (1, 0));
    assert_eq!(rig.sync.lastfm_queue_len(&rig.user.id).await.unwrap(), 0);
    assert_logs_clean();
}

#[tokio::test(flavor = "multi_thread")]
async fn one_malformed_play_is_dropped_without_holding_back_the_others() {
    let rig = Rig::new(Vec::new()).await;
    rig.connect().await;
    for index in 1..=3 {
        rig.record(Source::Opensubsonic, index, NOW_S - 100 + index as i64).await;
    }
    rig.fake.script(&[ScrobbleReply::Malformed, ScrobbleReply::Malformed]);
    let pass = rig.relay_pass().await;
    assert_eq!((pass.submitted, pass.rejected), (2, 1));
    let titles: Vec<String> = rig.fake.batches().iter().flatten().map(|play| play.title.clone()).collect();
    assert_eq!(titles, vec!["Played 2", "Played 3"]);
}

#[tokio::test(flavor = "multi_thread")]
async fn an_invalid_session_pauses_the_relay_and_shows_in_status_and_doctor() {
    let rig = Rig::new(Vec::new()).await;
    rig.connect().await;
    rig.record(Source::Opensubsonic, 1, NOW_S - 50).await;
    rig.fake.script(&[ScrobbleReply::InvalidSession]);
    let pass = rig.relay_pass().await;
    assert!(pass.paused);
    let record = rig.sync.lastfm_relay_record(&rig.user.id).await.unwrap().unwrap();
    assert!(record.paused_reason.unwrap().contains("lastfm connect"));
    let calls = rig.fake.inner.scrobble_calls.load(Ordering::SeqCst);
    rig.advance(7_200);
    assert!(rig.relay_pass().await.paused);
    assert_eq!(rig.fake.inner.scrobble_calls.load(Ordering::SeqCst), calls, "a paused relay sends nothing");

    let statuses = gather(&rig.sync, &rig.security).await.unwrap();
    assert!(problems(&statuses, true).iter().any(|problem| problem.contains("paused")));
    let mut printed = Vec::new();
    rig.desk().status(None, false, true, &mut |text: &str| printed.push(text.to_owned())).await.unwrap();
    assert!(printed.iter().any(|line| line.contains("PAUSED")));

    rig.connect().await;
    assert_eq!(rig.relay_pass().await.submitted, 1, "connecting again clears the pause and sends the waiting play");
    assert_logs_clean();
}

#[tokio::test(flavor = "multi_thread")]
async fn disconnect_forgets_the_session_and_the_queue() {
    let rig = Rig::new(Vec::new()).await;
    rig.connect().await;
    rig.record(Source::Opensubsonic, 1, NOW_S - 50).await;
    rig.relay_user_enqueue().await;
    let mut said = Vec::new();
    rig.desk().disconnect("alice", &mut |text: &str| said.push(text.to_owned())).await.unwrap();
    assert!(rig.security.lastfm_session(&rig.user.id).await.unwrap().is_none());
    assert!(rig.sync.lastfm_relay_record(&rig.user.id).await.unwrap().is_none());
    assert_eq!(rig.sync.lastfm_queue_len(&rig.user.id).await.unwrap(), 0);
    assert_eq!(rig.relay().run_cycle().await.len(), 0);
}

impl Rig {
    async fn relay_user_enqueue(&self) {
        self.sync.lastfm_enqueue_new(&self.user.id, self.now()).await.unwrap();
        assert_eq!(self.sync.lastfm_queue_len(&self.user.id).await.unwrap(), 1);
    }
}

async fn app_state(dir: &TempDir, fake: &Fake) -> AppState {
    let text = format!(
        "music_folder = \"{}\"\ndata_dir = \"{}\"\nlastfm_api_key = \"{API_KEY}\"\nlastfm_api_url = \"{}\"\nlastfm_sign_url = \"{}\"\nport = 4999\n",
        dir.path().display(),
        dir.file("data").display(),
        fake.api_url(),
        fake.sign_url()
    );
    std::fs::write(dir.file("config.toml"), text).unwrap();
    let config = Config::load(&dir.file("config.toml")).unwrap();
    assert_eq!(config.port, 4999, "flattened lastfm keys leave the other keys alone");
    assert!(!format!("{config:?}").contains(API_KEY));
    AppState::open(config).await.unwrap()
}

#[tokio::test(flavor = "multi_thread")]
async fn hello_lists_the_history_feature_only_for_a_user_whose_history_flows() {
    let dir = TempDir::new("lastfm-hello");
    let fake = Fake::start(plays(10, NOW_S - 600, 600)).await;
    let state = app_state(&dir, &fake).await;
    let user = state.0.security.create_user("alice", Role::Member).await.unwrap();
    let principal = security::Principal { user: user.id.clone(), role: Role::Member, device: None };
    assert!(!flaccy_server::lastfm::history_feature_for(&state, Some(&principal)).await);
    let api = Arc::new(LastfmApi::new(state.0.config.lastfm.endpoints(), API_KEY.to_owned(), "device".to_owned()));
    HistoryWorker::new(state.0.sync.clone(), api, Pacing::instant()).sync_user(&user.id, ACCOUNT).await.unwrap();
    assert!(flaccy_server::lastfm::history_feature_for(&state, Some(&principal)).await);
    assert!(!flaccy_server::lastfm::history_feature_for(&state, None).await);
    let stranger = security::Principal { user: UserId("nobody".into()), role: Role::Member, device: None };
    assert!(!flaccy_server::lastfm::history_feature_for(&state, Some(&stranger)).await);
}

#[tokio::test(flavor = "multi_thread")]
async fn the_running_server_syncs_relays_and_sends_now_playing_on_its_own() {
    let dir = TempDir::new("lastfm-run");
    let fake = Fake::start(plays(10, NOW_S - 600, 600)).await;
    let state = app_state(&dir, &fake).await;
    let user = state.0.security.create_user("alice", Role::Member).await.unwrap();
    state.0.sync.set_scalar_as_server(&user.id, ACCOUNT_KEY, json!(ACCOUNT)).await.unwrap();
    let api = flaccy_server::lastfm::client_for(&state.0.config, &state.0.security).await.unwrap();
    let desk = Desk { security: state.0.security.clone(), sync: state.0.sync.clone() };
    desk.connect(&api, "alice", &mut Cursor::new(b"\n".to_vec()), &mut |_: &str| {}).await.unwrap();
    let now = state.0.sync.now_ms() / 1000;
    let listen = ServerListen { source: Source::Opensubsonic, input: listen_input(1, now - 30) };
    state.0.sync.record_listens_as_server(&user.id, vec![listen]).await.unwrap();

    let running = tokio::spawn(flaccy_server::lastfm::run(state.clone()));
    let song = song_ref(9);
    let deadline = std::time::Instant::now() + Duration::from_secs(15);
    loop {
        flaccy_server::lastfm::note_now_playing(&user.id, &song);
        let history = state.0.sync.stats().await.unwrap().listens >= 10;
        let relayed = fake.batches().len() == 1;
        let announced = !fake.inner.now_playing.lock().unwrap().is_empty();
        if history && relayed && announced {
            break;
        }
        assert!(std::time::Instant::now() < deadline, "history {history}, relayed {relayed}, now playing {announced}");
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    running.abort();
    assert_logs_clean();
}

#[tokio::test(flavor = "multi_thread")]
async fn doctor_reports_a_paused_relay_a_stuck_history_and_stays_silent_when_nothing_is_set() {
    let rig = Rig::new(Vec::new()).await;
    let config_text = format!(
        "music_folder = \"{}\"\ndata_dir = \"{}\"\nlastfm_api_key = \"{API_KEY}\"\n",
        rig.dir.path().display(),
        rig.dir.path().display()
    );
    std::fs::write(rig.dir.file("config.toml"), config_text).unwrap();
    let config = Config::load(&rig.dir.file("config.toml")).unwrap();
    assert!(flaccy_server::lastfm::health::checks(&config).is_empty(), "nothing is set, so doctor says nothing");

    rig.connect().await;
    let healthy = flaccy_server::lastfm::health::checks(&config);
    assert!(healthy.iter().all(|check| !check.failed()) && healthy.len() == 1);

    rig.record(Source::Opensubsonic, 1, NOW_S - 50).await;
    rig.fake.script(&[ScrobbleReply::InvalidSession]);
    rig.relay_pass().await;
    rig.set_account().await;
    rig.fake.inner.fail_reads.store(1_000, Ordering::SeqCst);
    assert!(rig.history().sync_user(&rig.user.id, ACCOUNT).await.is_err());
    let lines: Vec<String> = flaccy_server::lastfm::health::checks(&config).iter().map(|check| check.line()).collect();
    assert!(lines.iter().any(|line| line.contains("paused") && line.contains("lastfm connect --user alice")), "{lines:?}");
    assert!(lines.iter().any(|line| line.contains("history for alice is stuck")), "{lines:?}");
    assert_secrets_absent(&lines.join("\n"));
}
