# security

`security.sqlite` (schema: PROTOCOL.md 10.1, migration 1) behind a cheap-to-clone `Store`.
One writer thread (`dbthread::DbThread`), `synchronous = FULL`, WAL, files mode 0600.
Secrets are shown once and stored as SHA-256 only. Times are Unix milliseconds.
Every mutation writes its audit row in the same `BEGIN IMMEDIATE` transaction.

## Open
- `Store::open(path)`, `Store::open_with_clock(path, Clock)`, `close()`.
- Creates the file 0600, migrates (copies the file to `<name>.premigrate-<v>.bak` first when it has data),
  refuses a file newer than the code. `acting_as(&UserId)` returns a handle whose audit rows name that actor.
- `incarnation()`, `bump_incarnation()` ("server.incarnate"), `server_id()`, `schema_version()`.

## Users
- `create_user(name, Role)`, `get_user(id)`, `find_user_by_name(name)`, `list_users()`, `set_role(id, Role)`,
  `ensure_owner(name)` (first admin, created when missing). Roles: admin, member, guest, pending.
- Names are unique ignoring case. The last admin cannot be demoted (`SecurityError::LastAdmin`).

## Enrollment
- `create_enrollment(user, ttl) -> code` (26 Crockford base32 chars, 128 bits).
- `redeem(code) -> Result<UserId, EnrollError>`: `Invalid` (wrong, used, expired: same answer) or
  `Locked { retry_after }` (five wrong codes in 60 s from anyone lock redemption for 60 s).
  Typed codes may have dashes, spaces, lower case, O for 0, I or L for 1.

## Devices
- `create_device(user, name, platform) -> (DeviceId, token)` (43 base64url chars, 256 bits).
- `authenticate(token) -> Option<Principal { user, role, device }>`; revoked devices give `None` at once.
- `touch_last_seen(device)` writes at most once a minute. `list_devices(Option<&UserId>)`,
  `rename_device`, `revoke_device`.

## API keys (OpenSubsonic)
- `create_api_key(user, name) -> (KeyId, key)` (64 hex chars), `list_api_keys(Option<&UserId>)`,
  `revoke_api_key(id)`, `authenticate_api_key(key) -> Option<Principal>` (`device: None`).
- `import_legacy(&Credentials) -> LegacyImport { imported, already_present, invalid }` adds the
  `credentials.toml` keys (name + SHA-256) to the first admin; needs an admin (`NoOwner`); idempotent.

## Audit
- `verify_audit() -> Result<(), VerifyError::BrokenAt(seq)>`, `audit_len()`, free functions `audit::append`, `audit::verify`.
- `hash = SHA-256(prev_hash 0 at 0 actor 0 action 0 detail)`, first `prev_hash` is 32 zero bytes.
  Actions: user.create, role.set, enroll.create, enroll.redeem, device.create, device.rename,
  device.revoke, key.create, key.revoke, key.import, lastfm.link, lastfm.unlink, server.incarnate.
- Cannot see the newest entry being deleted; nothing after it exists to disagree.

## Last.fm
- `set_lastfm_session(user, username, session_key)`, `lastfm_session(user)`, `delete_lastfm_session(user)`.
  The key is stored in clear (the scrobbler sends it); `Debug` hides it.

## dbthread
- `DbThread::open(path, Durability::{Full, Normal})`, `call(|conn| ...)` (FIFO, panics become
  `DbError::Panicked`), `close()`. `ReadPool::open(path, 4)` + `call(|conn| ...)` for read-only queries.
- `migrate(conn, file, &[Migration])`, `schema_version`, `snapshot_before_migrate`.
