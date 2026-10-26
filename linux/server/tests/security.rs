use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicI64, AtomicU32, Ordering};
use std::sync::Arc;
use std::time::Duration;

use flaccy_server::credentials::Credentials;
use flaccy_server::security::{Clock, EnrollError, Role, SecurityError, Store, UserId, VerifyError};
use rusqlite::Connection;

static NEXT_DIR: AtomicU32 = AtomicU32::new(0);
const START: i64 = 1_790_000_000_000;

struct TempDir(PathBuf);

impl TempDir {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "flaccy-security-{}-{}",
            std::process::id(),
            NEXT_DIR.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir_all(&path).unwrap();
        Self(path)
    }

    fn database(&self) -> PathBuf {
        self.0.join("security.sqlite")
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn manual_clock() -> (Clock, Arc<AtomicI64>) {
    let now = Arc::new(AtomicI64::new(START));
    let reader = now.clone();
    (Arc::new(move || reader.load(Ordering::SeqCst)), now)
}

async fn open_store() -> (Store, TempDir, Arc<AtomicI64>) {
    let dir = TempDir::new();
    let (clock, now) = manual_clock();
    let store = Store::open_with_clock(&dir.database(), clock).await.unwrap();
    (store, dir, now)
}

fn advance(now: &AtomicI64, by: Duration) {
    now.fetch_add(by.as_millis() as i64, Ordering::SeqCst);
}

fn raw(path: &Path) -> Connection {
    Connection::open(path).unwrap()
}

fn audit_actions(path: &Path) -> Vec<String> {
    let connection = raw(path);
    let mut statement = connection.prepare("SELECT action FROM audit ORDER BY seq").unwrap();
    let actions = statement.query_map([], |row| row.get(0)).unwrap().collect::<Result<Vec<String>, _>>().unwrap();
    actions
}

async fn owner(store: &Store) -> UserId {
    store.ensure_owner("marcus").await.unwrap().id
}

#[tokio::test]
async fn users_are_created_found_listed_and_given_roles() {
    let (store, _dir, _now) = open_store().await;
    let admin = store.create_user("Marcus", Role::Admin).await.unwrap();
    let guest = store.create_user("Visitor", Role::Guest).await.unwrap();
    assert_eq!(store.get_user(&admin.id).await.unwrap().unwrap(), admin);
    assert_eq!(store.get_user(&UserId("nobody".into())).await.unwrap(), None);
    assert_eq!(store.find_user_by_name("  marcus ").await.unwrap().unwrap().id, admin.id);
    assert_eq!(store.list_users().await.unwrap().iter().map(|user| user.name.as_str()).collect::<Vec<_>>(), ["Marcus", "Visitor"]);
    assert!(matches!(store.create_user("MARCUS", Role::Member).await, Err(SecurityError::NameTaken(_))));
    assert!(matches!(store.create_user("  ", Role::Member).await, Err(SecurityError::InvalidName(_))));
    store.set_role(&guest.id, Role::Member).await.unwrap();
    assert_eq!(store.get_user(&guest.id).await.unwrap().unwrap().role, Role::Member);
    assert!(matches!(store.set_role(&UserId("nobody".into()), Role::Guest).await, Err(SecurityError::UnknownUser(_))));
    assert!(matches!(store.set_role(&admin.id, Role::Guest).await, Err(SecurityError::LastAdmin)));
    store.set_role(&guest.id, Role::Admin).await.unwrap();
    store.set_role(&admin.id, Role::Pending).await.unwrap();
    assert_eq!(store.get_user(&admin.id).await.unwrap().unwrap().role, Role::Pending);
}

#[tokio::test]
async fn ensure_owner_returns_the_first_admin_and_never_adds_a_second() {
    let (store, _dir, _now) = open_store().await;
    store.create_user("Helper", Role::Member).await.unwrap();
    let first = store.ensure_owner("marcus").await.unwrap();
    assert_eq!((first.role, first.name.as_str()), (Role::Admin, "marcus"));
    let again = store.ensure_owner("someone else").await.unwrap();
    assert_eq!(again.id, first.id);
    assert_eq!(store.list_users().await.unwrap().len(), 2);
}

#[tokio::test]
async fn an_enrollment_code_works_once_and_only_its_hash_is_stored() {
    let (store, dir, _now) = open_store().await;
    let user = owner(&store).await;
    let code = store.create_enrollment(&user, Duration::from_secs(600)).await.unwrap();
    assert_eq!(code.len(), 26);
    let stored: Vec<u8> = raw(&dir.database()).query_row("SELECT code_hash FROM enrollments", [], |row| row.get(0)).unwrap();
    assert_eq!(stored.len(), 32);
    assert_ne!(stored, code.as_bytes());
    assert_eq!(store.redeem(&code).await.unwrap(), user);
    assert!(matches!(store.redeem(&code).await, Err(EnrollError::Invalid)));
}

#[tokio::test]
async fn a_typed_code_with_dashes_and_lower_case_redeems() {
    let (store, _dir, _now) = open_store().await;
    let user = owner(&store).await;
    let code = store.create_enrollment(&user, Duration::from_secs(600)).await.unwrap();
    let typed = format!("{}-{}-{}", &code[..9], &code[9..18], &code[18..]).to_lowercase();
    assert_eq!(store.redeem(&typed).await.unwrap(), user);
}

#[tokio::test]
async fn an_expired_code_is_refused_like_a_wrong_one() {
    let (store, _dir, now) = open_store().await;
    let user = owner(&store).await;
    let code = store.create_enrollment(&user, Duration::from_secs(600)).await.unwrap();
    advance(&now, Duration::from_secs(600));
    let refusal = store.redeem(&code).await.unwrap_err();
    assert!(matches!(refusal, EnrollError::Invalid));
    assert!(!refusal.to_string().contains(&code));
    assert!(matches!(store.create_enrollment(&UserId("nobody".into()), Duration::from_secs(1)).await, Err(SecurityError::UnknownUser(_))));
}

#[tokio::test]
async fn five_wrong_codes_lock_redemption_for_a_minute_even_for_the_right_code() {
    let (store, _dir, now) = open_store().await;
    let user = owner(&store).await;
    let code = store.create_enrollment(&user, Duration::from_secs(3600)).await.unwrap();
    for _ in 0..5 {
        advance(&now, Duration::from_secs(1));
        assert!(matches!(store.redeem("0000000000000000000000000A").await, Err(EnrollError::Invalid)));
    }
    advance(&now, Duration::from_secs(1));
    match store.redeem(&code).await {
        Err(EnrollError::Locked { retry_after }) => assert!(retry_after <= Duration::from_secs(60) && retry_after > Duration::from_secs(50)),
        other => panic!("expected a lock, got {other:?}"),
    }
    advance(&now, Duration::from_secs(60));
    assert_eq!(store.redeem(&code).await.unwrap(), user);
}

#[tokio::test]
async fn four_wrong_codes_do_not_lock_and_old_failures_expire() {
    let (store, _dir, now) = open_store().await;
    let user = owner(&store).await;
    let code = store.create_enrollment(&user, Duration::from_secs(3600)).await.unwrap();
    for _ in 0..4 {
        assert!(matches!(store.redeem("garbage").await, Err(EnrollError::Invalid)));
    }
    advance(&now, Duration::from_secs(61));
    for _ in 0..4 {
        assert!(matches!(store.redeem("garbage").await, Err(EnrollError::Invalid)));
    }
    assert_eq!(store.redeem(&code).await.unwrap(), user);
}

#[tokio::test]
async fn a_concurrent_burst_of_wrong_codes_cannot_exceed_the_limit() {
    let (store, _dir, _now) = open_store().await;
    let mut attempts = Vec::new();
    for _ in 0..40 {
        let handle = store.clone();
        attempts.push(tokio::spawn(async move { handle.redeem("0000000000000000000000000B").await }));
    }
    let mut invalid = 0;
    for attempt in attempts {
        if matches!(attempt.await.unwrap(), Err(EnrollError::Invalid)) {
            invalid += 1;
        }
    }
    assert!(invalid <= 5, "{invalid} guesses got through");
}

#[tokio::test]
async fn a_device_token_authenticates_until_the_device_is_revoked() {
    let (store, dir, _now) = open_store().await;
    let user = owner(&store).await;
    let (device, token) = store.create_device(&user, "iPhone", "ios").await.unwrap();
    assert_eq!(token.len(), 43);
    let stored: Vec<u8> = raw(&dir.database()).query_row("SELECT token_hash FROM devices", [], |row| row.get(0)).unwrap();
    assert_eq!(stored.len(), 32);
    assert!(!String::from_utf8_lossy(&stored).contains(&token));
    let principal = store.authenticate(&token).await.unwrap().unwrap();
    assert_eq!((principal.user.clone(), principal.role, principal.device.clone()), (user, Role::Admin, Some(device.clone())));
    assert_eq!(store.authenticate("not-a-token").await.unwrap(), None);
    assert_eq!(store.authenticate("").await.unwrap(), None);
    assert!(store.revoke_device(&device).await.unwrap());
    assert_eq!(store.authenticate(&token).await.unwrap(), None);
    assert!(!store.revoke_device(&device).await.unwrap());
    assert!(matches!(store.revoke_device(&flaccy_server::security::DeviceId("nope".into())).await, Err(SecurityError::UnknownDevice(_))));
}

#[tokio::test]
async fn devices_are_listed_per_user_or_for_everyone_and_renamed() {
    let (store, _dir, _now) = open_store().await;
    let admin = owner(&store).await;
    let member = store.create_user("Sam", Role::Member).await.unwrap().id;
    let (phone, _) = store.create_device(&admin, "iPhone", "ios").await.unwrap();
    let (laptop, _) = store.create_device(&member, "Laptop", "plan9").await.unwrap();
    assert_eq!(store.list_devices(Some(&admin)).await.unwrap().len(), 1);
    let everyone = store.list_devices(None).await.unwrap();
    assert_eq!(everyone.iter().map(|device| device.platform.as_str()).collect::<Vec<_>>(), ["ios", "other"]);
    store.rename_device(&phone, "Marcus's iPhone").await.unwrap();
    assert_eq!(store.list_devices(Some(&admin)).await.unwrap()[0].name, "Marcus's iPhone");
    store.revoke_device(&laptop).await.unwrap();
    assert!(store.list_devices(Some(&member)).await.unwrap()[0].revoked_at.is_some());
    assert!(matches!(store.create_device(&UserId("nobody".into()), "x", "ios").await, Err(SecurityError::UnknownUser(_))));
    assert!(matches!(store.rename_device(&flaccy_server::security::DeviceId("nope".into()), "x").await, Err(SecurityError::UnknownDevice(_))));
}

#[tokio::test]
async fn last_seen_is_written_at_most_once_a_minute() {
    let (store, _dir, now) = open_store().await;
    let user = owner(&store).await;
    let (device, _) = store.create_device(&user, "iPhone", "ios").await.unwrap();
    assert!(store.touch_last_seen(&device).await.unwrap());
    advance(&now, Duration::from_secs(30));
    assert!(!store.touch_last_seen(&device).await.unwrap());
    advance(&now, Duration::from_secs(30));
    assert!(store.touch_last_seen(&device).await.unwrap());
    let seen = store.list_devices(None).await.unwrap()[0].last_seen_at;
    assert_eq!(seen, Some(START + 60_000));
}

#[tokio::test]
async fn api_keys_authenticate_until_revoked_and_names_are_unique_per_user() {
    let (store, dir, _now) = open_store().await;
    let user = owner(&store).await;
    let (id, key) = store.create_api_key(&user, "symfonium").await.unwrap();
    assert_eq!(key.len(), 64);
    let stored: Vec<u8> = raw(&dir.database()).query_row("SELECT key_hash FROM api_keys", [], |row| row.get(0)).unwrap();
    assert_eq!(stored.len(), 32);
    let principal = store.authenticate_api_key(&key).await.unwrap().unwrap();
    assert_eq!((principal.user, principal.device), (user.clone(), None));
    assert_eq!(store.authenticate_api_key("someone-elses").await.unwrap(), None);
    assert!(matches!(store.create_api_key(&user, "symfonium").await, Err(SecurityError::NameTaken(_))));
    assert_eq!(store.list_api_keys(Some(&user)).await.unwrap()[0].id, id);
    assert!(store.revoke_api_key(&id).await.unwrap());
    assert_eq!(store.authenticate_api_key(&key).await.unwrap(), None);
    assert!(!store.revoke_api_key(&id).await.unwrap());
    assert!(store.list_api_keys(None).await.unwrap()[0].revoked_at.is_some());
    store.create_api_key(&user, "symfonium").await.unwrap();
    assert!(matches!(store.revoke_api_key(&flaccy_server::security::KeyId("nope".into())).await, Err(SecurityError::UnknownKey(_))));
}

fn legacy_credentials() -> (Credentials, String) {
    let mut credentials = Credentials {
        username: "flaccy".into(),
        password: "sesame-seed".into(),
        keys: Vec::new(),
    };
    let key = credentials.add_key("iphone", "2026-10-20T08:00:00Z").unwrap();
    credentials.add_key("kitchen", "not a date").unwrap();
    (credentials, key)
}

#[tokio::test]
async fn legacy_keys_import_once_and_still_authenticate() {
    let (store, _dir, _now) = open_store().await;
    let (credentials, key) = legacy_credentials();
    assert!(matches!(store.import_legacy(&credentials).await, Err(SecurityError::NoOwner)));
    let user = owner(&store).await;
    let first = store.import_legacy(&credentials).await.unwrap();
    assert_eq!((first.imported, first.already_present, first.invalid), (2, 0, 0));
    let second = store.import_legacy(&credentials).await.unwrap();
    assert_eq!((second.imported, second.already_present, second.invalid), (0, 2, 0));
    let keys = store.list_api_keys(Some(&user)).await.unwrap();
    let mut names = keys.iter().map(|key| key.name.as_str()).collect::<Vec<_>>();
    names.sort();
    assert_eq!(names, ["iphone", "kitchen"]);
    let iphone = keys.iter().find(|key| key.name == "iphone").unwrap();
    let kitchen = keys.iter().find(|key| key.name == "kitchen").unwrap();
    assert_eq!(iphone.created_at, 1_792_483_200_000);
    assert_eq!(kitchen.created_at, START);
    assert_eq!(store.authenticate_api_key(&key).await.unwrap().unwrap().user, user);
    store.revoke_api_key(&iphone.id).await.unwrap();
    store.import_legacy(&credentials).await.unwrap();
    assert_eq!(store.authenticate_api_key(&key).await.unwrap(), None);
}

#[tokio::test]
async fn a_legacy_key_with_a_malformed_hash_is_counted_and_skipped() {
    let (store, _dir, _now) = open_store().await;
    owner(&store).await;
    let (mut credentials, _) = legacy_credentials();
    credentials.keys[1].sha256 = "xyz".into();
    let outcome = store.import_legacy(&credentials).await.unwrap();
    assert_eq!((outcome.imported, outcome.invalid), (1, 1));
}

#[tokio::test]
async fn every_mutation_is_audited_and_the_chain_verifies() {
    let (store, dir, _now) = open_store().await;
    let user = owner(&store).await;
    let member = store.create_user("Sam", Role::Member).await.unwrap().id;
    store.set_role(&member, Role::Guest).await.unwrap();
    let code = store.create_enrollment(&user, Duration::from_secs(60)).await.unwrap();
    store.redeem(&code).await.unwrap();
    let (device, _) = store.create_device(&user, "iPhone", "ios").await.unwrap();
    store.revoke_device(&device).await.unwrap();
    let (key, _) = store.create_api_key(&user, "app").await.unwrap();
    store.revoke_api_key(&key).await.unwrap();
    store.verify_audit().await.unwrap();
    assert_eq!(
        audit_actions(&dir.database()),
        ["user.create", "user.create", "role.set", "enroll.create", "enroll.redeem", "device.create", "device.revoke", "key.create", "key.revoke"]
    );
    assert_eq!(store.audit_len().await.unwrap(), 9);
}

#[tokio::test]
async fn the_audit_actor_is_the_handle_that_acted() {
    let (store, dir, _now) = open_store().await;
    let user = owner(&store).await;
    store.acting_as(&user).create_user("Sam", Role::Member).await.unwrap();
    let actors: Vec<Option<String>> = {
        let connection = raw(&dir.database());
        let mut statement = connection.prepare("SELECT actor FROM audit ORDER BY seq").unwrap();
        let rows = statement.query_map([], |row| row.get(0)).unwrap().collect::<Result<_, _>>().unwrap();
        rows
    };
    assert_eq!(actors, [None, Some(user.to_string())]);
}

#[tokio::test]
async fn a_tampered_audit_row_is_found() {
    let (store, dir, _now) = open_store().await;
    let user = owner(&store).await;
    for name in ["a", "b", "c"] {
        store.create_device(&user, name, "linux").await.unwrap();
    }
    store.verify_audit().await.unwrap();
    raw(&dir.database()).execute("UPDATE audit SET detail = 'user=forged' WHERE seq = 3", []).unwrap();
    assert!(matches!(store.verify_audit().await, Err(VerifyError::BrokenAt(3))));
}

#[tokio::test]
async fn a_removed_audit_row_breaks_the_chain_at_its_successor() {
    let (store, dir, _now) = open_store().await;
    let user = owner(&store).await;
    for name in ["a", "b", "c"] {
        store.create_device(&user, name, "linux").await.unwrap();
    }
    raw(&dir.database()).execute("DELETE FROM audit WHERE seq = 2", []).unwrap();
    assert!(matches!(store.verify_audit().await, Err(VerifyError::BrokenAt(3))));
}

#[tokio::test]
async fn a_database_from_a_newer_version_is_refused_with_a_helpful_message() {
    let dir = TempDir::new();
    Store::open(&dir.database()).await.unwrap().close().await.unwrap();
    raw(&dir.database()).execute("INSERT INTO schema_migrations(version, applied_at) VALUES (99, 0)", []).unwrap();
    let refusal = Store::open(&dir.database()).await.err().unwrap().to_string();
    assert!(refusal.contains("security.sqlite"), "{refusal}");
    assert!(refusal.contains("99") && refusal.contains("up to 1"), "{refusal}");
    assert!(refusal.contains("install that version again") || refusal.contains("restore"), "{refusal}");
}

#[tokio::test]
async fn reopening_keeps_the_data_the_ids_and_the_incarnation() {
    let dir = TempDir::new();
    let first = Store::open(&dir.database()).await.unwrap();
    let user = owner(&first).await;
    let incarnation = first.incarnation().await.unwrap();
    let server_id = first.server_id().await.unwrap();
    assert_eq!((incarnation.len(), server_id.len()), (36, 36));
    assert_ne!(incarnation, server_id);
    assert_eq!(first.schema_version().await.unwrap(), 1);
    first.close().await.unwrap();
    let second = Store::open(&dir.database()).await.unwrap();
    assert_eq!(second.get_user(&user).await.unwrap().unwrap().name, "marcus");
    assert_eq!(second.incarnation().await.unwrap(), incarnation);
    assert_eq!(second.server_id().await.unwrap(), server_id);
    let bumped = second.bump_incarnation().await.unwrap();
    assert_ne!(bumped, incarnation);
    assert_eq!(second.incarnation().await.unwrap(), bumped);
    assert_eq!(second.server_id().await.unwrap(), server_id);
    second.verify_audit().await.unwrap();
}

#[tokio::test]
async fn last_fm_sessions_are_set_replaced_read_and_deleted() {
    let (store, _dir, _now) = open_store().await;
    let user = owner(&store).await;
    assert_eq!(store.lastfm_session(&user).await.unwrap(), None);
    store.set_lastfm_session(&user, "marcus_fm", "key-one").await.unwrap();
    store.set_lastfm_session(&user, "marcus_fm", "key-two").await.unwrap();
    let session = store.lastfm_session(&user).await.unwrap().unwrap();
    assert_eq!((session.username.as_str(), session.session_key.as_str()), ("marcus_fm", "key-two"));
    assert!(!format!("{session:?}").contains("key-two"));
    assert!(matches!(store.set_lastfm_session(&UserId("nobody".into()), "x", "y").await, Err(SecurityError::UnknownUser(_))));
    assert!(store.delete_lastfm_session(&user).await.unwrap());
    assert!(!store.delete_lastfm_session(&user).await.unwrap());
    assert_eq!(store.lastfm_session(&user).await.unwrap(), None);
    store.verify_audit().await.unwrap();
}

#[cfg(unix)]
#[tokio::test]
async fn the_database_and_its_side_files_are_private() {
    use std::os::unix::fs::PermissionsExt;
    let (store, dir, _now) = open_store().await;
    let user = owner(&store).await;
    store.set_lastfm_session(&user, "marcus_fm", "secret-session").await.unwrap();
    for suffix in ["", "-wal", "-shm"] {
        let name = format!("security.sqlite{suffix}");
        let mode = std::fs::metadata(dir.0.join(&name)).map(|meta| meta.permissions().mode() & 0o777);
        assert_eq!(mode.ok(), Some(0o600), "{name}");
    }
}

#[tokio::test]
async fn many_concurrent_writers_all_land_and_the_chain_holds() {
    let (store, _dir, _now) = open_store().await;
    let user = owner(&store).await;
    let mut tasks = Vec::new();
    for number in 0..60 {
        let handle = store.clone();
        let user = user.clone();
        tasks.push(tokio::spawn(async move { handle.create_device(&user, &format!("device {number}"), "linux").await }));
    }
    for task in tasks {
        task.await.unwrap().unwrap();
    }
    assert_eq!(store.list_devices(None).await.unwrap().len(), 60);
    store.verify_audit().await.unwrap();
}
