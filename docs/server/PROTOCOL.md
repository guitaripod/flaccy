# Flaccy Server protocol, version 1

The contract between `flaccy-server` and every Flaccy client. The design reasoning is in `roadmap/proposals/flaccy-home-server-2026-10-26.md` (monorepo); this file is the exact wire and storage behaviour. Where the two disagree, this file wins and the proposal is wrong.

## 1. Conventions

- Base path `/flaccy/v1`. JSON, UTF-8, `Content-Type: application/json`. Responses may be gzip or br compressed.
- Every call except `GET /hello` and `POST /devices` needs `Authorization: Bearer <device token>`.
- Errors: HTTP status plus `{"error": {"code": "<snake_case>", "message": "<what failed, the cause, the next step>", "hint": "<optional>"}}`.
- Ids that clients mint (playlist, entry, device, instance, event) are UUIDv7 in lowercase hyphenated form, except `eventId` and `songKey`, defined below.
- A request carrying an `Origin` header, `Sec-Fetch-Site: cross-site`, or a `Host` that is not an allowed host (section 2) is answered `403 browser_refused`, on `/rest` as well. CORS is never enabled.
- Clients send `Flaccy-Incarnation: <uuid>`, the incarnation they last saw, on every authenticated call once they have one. If it differs from the server's, the server applies nothing and answers `409 incarnation_changed` with the current value in `error.incarnation`; the client then runs the reset of section 6.2. The same field is added to `409 cookie_ahead`.
- `Flaccy-Protocol: 1` is sent by clients and answered by the server. The server speaks protocol 1 and ignores unknown JSON fields; clients ignore unknown fields too.

### 1.1 Stamps

A stamp is an `i64`: `(wall_ms << 16) | counter`, `counter` 16 bits. Stamps compare as integers. A client produces `next = max(last + 1, ((now_ms + server_offset_ms) << 16))`; `server_offset_ms` comes from `hello.serverTimeMs - local_now_ms` and is refreshed by every response's `serverTimeMs`.

The server keeps `server_hlc: i64`, persisted in `server_meta`, never decreasing. `server_hlc.next()` returns `max(wall_ms << 16, server_hlc + 1)` and stores it. A mutation's stored stamp is `min(client_stamp, server_hlc.next())`; when the client stamp is larger the server assigns `server_hlc.next()` (strictly increasing). A field accepts a mutation when its stored stamp is **greater than or equal to** the field's current stamp (ties: the later-applied mutation wins). If the wall clock is more than one hour behind `server_hlc`, writes answer `503 clock_behind`.

### 1.2 Song identity

`songKey` is 32 lowercase hex characters: the first 16 bytes of `SHA-256("fsk1" || artistKey || 0x00 || titleKey)` where the two keys are the shared normalizers `ListenHistory.trackKey` produces (`recap::track_key` on Rust). The core crate exposes `song_key(artist_key, title_key)`.

`SongRef` (all fields optional except `songKey`, `title`, `artist`):
```
{ "songKey": "…", "title": "", "artist": "", "album": "", "durationMs": 0,
  "fp": null, "mbid": null, "albumKey": null, "relPath": null }
```

## 2. Modes and reachability

- **Easy mode** (default): the server binds the host's tailnet addresses (100.64.0.0/10, fd7a:115c:a1e0::/48) and loopback, re-evaluating when a network interface changes, and closes any accepted connection whose peer address is outside those ranges and loopback before reading a byte. Plain HTTP; no identity headers are read.
- **Household mode**: a Unix socket (mode 0600) or loopback TCP behind `tailscale serve`. Identity headers are trusted only on the socket.
- Allowed hosts, compared without the port and ignoring case. A `Host` is allowed when it is: an IP literal (IPv4, or IPv6 in brackets); a single-label name such as `arch`; `localhost`; one of the machine's own names (its host name, the short form, and the aliases `/etc/hosts` gives it); a name ending in `.ts.net`, `.local`, `.lan`, `.home.arpa` or `.internal`; or listed in the configured `hosts`, either exactly or as `*.example.com` for everything under a domain. Any other name with a dot, such as `evil.example.com` or `100.64.0.1.evil.com`, is refused: that is what a DNS-rebinding page sends, since a browser can only reach this server through a name it resolved.

## 3. Identity and enrollment

### 3.1 `GET /hello` (no token)
```
{ "protocol": [1], "server": {"name": "arch", "version": "1.0.0", "schema": 1},
  "features": ["sync", "live", "lastfm.history"], "mode": "easy",
  "serverTimeMs": 1790000000000, "incarnation": "<uuid>",
  "caller": null | {"user": "<id>", "role": "admin|member|guest|pending", "device": "<id or null>"} }
```
`features` lists only what this build implements.

### 3.2 `POST /devices` (no token; a code)
Request: `{ "enroll": "<code>", "name": "iPhone", "platform": "ios|macos|linux|windows|other", "instance": "<uuid>" }`.
Response `201`: `{ "device": "<id>", "token": "<256-bit base64url>", "user": {"id","name","role"}, "serverTimeMs": …, "incarnation": "…" }`.
The code is 128 random bits, base32 (Crockford) without padding, single use, valid ten minutes, created by `flaccy-server enroll --user <name>`. Wrong, used or expired code: `401 enroll_invalid` (same body for all three). Throttle: five wrong codes in a minute from one source address answer `429` to that address for a minute, and sixty from all addresses together answer `429` to everyone for a minute; a lock on one address never blocks another. A code is spent only by an enrollment that finishes, so a failure after the code was found good (a full disk, say) leaves it usable.

Household mode only: a request on the trusted socket with tailnet identity may omit `enroll`.

### 3.3 Other identity routes
`GET /devices` (own devices; admin: all), `PATCH /devices/{id}` `{name}` (owner or admin), `DELETE /devices/{id}` (revoke; owner or admin; effective on the next request; the device's open live sockets close at once). `GET /me` `{user, role, devices}`.

## 4. Entities

Every synced thing is an *entity* `(kind, id)` with a JSON `value`. Kinds and ids:

| kind | id | value |
|---|---|---|
| `playlist` | playlist id | `{id, owner, name, coverBlob, visibility, alive, createdAt, stamps:{name, cover, visibility, alive}}` |
| `playlist_entry` | entry id | `{id, playlist, ref: SongRef, pos, alive, stamps:{ref, pos, alive}}` |
| `love` | `songKey` | `{songKey, ref, loved, stamp}` |
| `rating` | `songKey` | `{songKey, ref, rating, stamp}` (`rating` 1 to 5 or null) |
| `scalar` | key | `{key, value, deleted, stamp}` |
| `session` | device id | `{device, session, stamp}` (`session` any JSON object up to 64 KiB) |
| `listen` | eventId | `{eventId, ts, ref, playedS, source, recorded, device, suppressed}` |

`visibility` is `private` or `household`. `alive` is a boolean. `createdAt` is Unix seconds. `ts` is Unix seconds. `source` is `flaccy`, `lastfm`, `opensubsonic` or `migrated`. `eventId` is 24 lowercase hex characters (12 bytes): clients derive it as the first 12 bytes of `SHA-256("rec" || deviceId || instance || counter)`; the server derives Last.fm ones as `SHA-256("lfm" || account || ts || songKey)` and migrated ones as `SHA-256("mig" || ts || titleKey || artistKey)`. Parts are concatenated with no separator and integers (`counter`, `ts`) are written in decimal ASCII.

Scalar keys are validated by prefix: `pref/…` (≤ 4 KiB), `eq/…`, `lyr/<songKey>` (integer milliseconds), `meta/<songKey>` (object), `want/…`, `lastfm/…`, `offline/…`. Unknown prefixes are `invalid`.

## 5. Mutations

A mutation: `{"id": <int>, "name": "<name>", "stamp": <i64>, "args": {…}}`. Names and arguments:

| name | args | effect |
|---|---|---|
| `playlist.create` | `{id, name, entries?: [{id, ref}]}` | Creates the playlist alive, owner is the caller; initial entries appended in order. On an existing id: `noop` for its owner, `invalid forbidden` for anyone else |
| `playlist.rename` | `{id, name}` | Sets `name` |
| `playlist.setCover` | `{id, blob}` | Sets `coverBlob` to a blob the caller uploaded and the server still holds, otherwise `invalid bad_args` |
| `playlist.clearCover` | `{id}` | Clears `coverBlob` |
| `playlist.delete` | `{id}` | `alive = false` |
| `playlist.restore` | `{id}` | `alive = true` |
| `playlist.setVisibility` | `{id, visibility}` | owner or admin only |
| `entry.insert` | `{id, playlist, ref, place}` | New alive entry at `place` |
| `entry.insertMany` | `{playlist, entries:[{id, ref}], place}` | Several entries, in order, at `place` |
| `entry.move` | `{id, place}` | Moves an entry; `noop` if the stamp is older than `stamps.pos`; an entry already between the neighbours of `place` keeps its `pos` and only takes the stamp |
| `entry.remove` | `{id}` | `alive = false`, sticky: it applies at any stamp, nothing revives the entry, and `stamps.alive` keeps the larger stamp |
| `love.set` | `{songKey, ref, loved}` | Last writer |
| `rating.set` | `{songKey, ref, rating}` | Last writer |
| `listen.record` | `{listens:[{eventId, ts, ref, playedS, recorded}]}` | Idempotent by `eventId` per user, so one user's event id never blocks another's; runs the ledger |
| `session.save` | `{session}` | Writes the caller device's session |
| `scalar.set` | `{key, value}` | Last writer per key |
| `scalar.clear` | `{key}` | `deleted = true` |
| `device.rename` | `{name}` | Names the caller device |
| `state.reseed` | `{entities:[{kind, id, value}]}` | Last-writer upsert of full entities carrying their own stamps; used after a restore. Merged field by field, an entry stays dead once either side has it dead, playlists must be owned by the caller, entries need their playlist (existing or in the same call), `listen` is refused, and any `invalid` entity rolls back the whole mutation. At most 1,000 entities and 400 KB of arguments (`invalid too_large`), so a larger base is sent as several reseeds, playlists before their entries; no playlist may end past 20,000 alive or 40,000 entries in all. Every stamp is lowered to the server clock like a push's, a tombstone does not replace a live value of the same stamp, and a playlist's `coverBlob` must be a blob the caller uploaded (`invalid bad_args`) |

`place` is `{"kind":"first"}`, `{"kind":"last"}`, `{"kind":"after","id":"<entry id>"}` or `{"kind":"before","id":"<entry id>"}`.

**Results**: `applied` (changed state, which includes a newer stamp on an unchanged value), `noop` (valid but not newer than the field's stamp, or the identical write already stored), `invalid` (with `code`: `unknown_playlist`, `unknown_anchor`, `bad_args`, `bad_key`, `forbidden`, `too_large`), `unsupported` (unknown name). The server consumes the mutation id in every case.

**Dead entities**: field writes to a dead playlist or entry are stored with their stamps and applied; they are merely not shown. `playlist.restore` reveals them. `entry.move` and `entry.remove` on an entry id the playlist does not hold are `invalid unknown_anchor`; inserting an id that already exists is a `noop`. Every `invalid` result leaves state untouched.

**`entry.insert` anchor rules**: an anchor that exists, alive or not, resolves by its `pos`. An unknown anchor, or an unknown `playlist`, is `invalid unknown_anchor` / `unknown_playlist`. `first` and `last` always resolve. A playlist's alive entries are ordered by `(pos, id)`.

**Server-computed `pos`**: new `pos` is `between(prev, next)` where `prev` and `next` are the `pos` of the neighbours in the full ordered list (dead entries included) at the place; `between` is §7. A move sets `stamps.pos` to the stored stamp. When any `pos` in a playlist exceeds 64 characters the server rewrites all of that playlist's `pos` values in the same transaction (evenly spaced, same order) and emits a change per entry.

**Permissions**: a member may write only their own playlists, loves, ratings, scalars, sessions and listens, and household playlists' entries and name; `setVisibility`, `delete`, `restore`, `setCover` and `clearCover` on a household playlist need its owner or an admin. An admin has no access to another user's private playlist. A guest or a pending device may write nothing (`invalid forbidden`).

## 6. Sync calls

### 6.1 `POST /sync/push`
```
{ "device": "<id>", "instance": "<uuid>", "mutations": [ … ] }
```
At most 500 mutations and 1 MiB. Mutations are applied in order, each in its own transaction that also advances `last_mutation_id` for `(device, instance)`.

The retry and gap checks below run over the whole request before the first mutation applies, so a `409` leaves nothing applied.

- `id <= last_mutation_id`: a retry. If the stored argument hash for that id equals the hash of this mutation's `name` + canonical `args`, answer the stored status; otherwise answer `409 instance_conflict` for the whole request and apply nothing.
- `id == last_mutation_id + 1`: applied.
- `id > last_mutation_id + 1`: `409 mutation_gap {"have": <last_mutation_id>}`, nothing applied.
- A new `instance` for a known device starts at `last_mutation_id = 0`.

Response `200`: `{"results": [{"id", "status", "code"?}], "serverTimeMs": …}`.

The server keeps the stored result of the newest 1,000 mutations of each device and of the last 30 days, and prunes the rest daily. A retry of a pruned id is answered `409 instance_conflict`, which sends the client to a new instance as above.

On `409 instance_conflict` a client also gives every recorded play it has no answer for a new `event_id` under the new instance (`event_id_rec` with a fresh counter), in its own history and in the queued `listen.record`, and reads `GET /listens` again from the start. A restored backup or a copied database reuses `(instance, counter)` pairs that the server already spent on other plays; without new ids the server would take the new play for a repeat of the old one, answer it as applied and drop it. A play the server did hold under its old id and now receives under a new one is suppressed by the ledger (same second, same song).

### 6.2 `GET /sync/pull?since=<seq>&limit=<n>`
`limit` ≤ 5000, default 1000. Returns state entities (every kind except `listen`) whose change `seq` is greater than `since`, ascending, for the caller's scope plus `household`:
```
{ "head": <int>, "incarnation": "<uuid>", "lastMutationId": <int>, "more": <bool>, "serverTimeMs": …,
  "changes": [ {"seq", "kind", "id", "deleted": <bool>, "value": {…}} ] }
```
`lastMutationId` is for the caller's `(device, instance)` (the `instance` is the query parameter `instance=`; absent: 0) and is read in the same transaction as `changes`. `head` is the highest `seq` in the scope at that snapshot. When `more` is false the client's new cookie is `head`; otherwise the last returned `seq`. `deleted` is true when the entity is dead (`alive = false`, `loved = false`, `deleted`, or a retired record); its `value` is still present.

A client retires a pending mutation only from a response with `more = false`, and only when its push was answered and `id <= lastMutationId`; a push result only marks a mutation acknowledged or, when `invalid` or `unsupported`, failed. A failed mutation is dropped from the visible state at once. On a different `incarnation`, or after `409 cookie_ahead`, the client builds a `state.reseed` of every entity of its base that it may write, drops its base, restarts at `since = 0` under a new `instance`, and pushes the reseed as id 1 followed by its unretired pending mutations renumbered from 2, refused ones included (a restored server answers `invalid` for want of state until the client learns of the new incarnation); what it shows meanwhile is the reseed and the pending mutations folded over the pulled state. A base kept across a reset would hold entries whose playlist the new server never had. On `409 instance_conflict` it moves its pending mutations to a new `instance` the same way.

`since = 0` is the bootstrap. A `since` greater than the server's current maximum `seq` is answered `409 cookie_ahead`; the client treats it like a new `incarnation`.

### 6.3 `GET /listens`
`GET /listens?before=<unix ts>&limit=<n>` newest first (n ≤ 5000), `GET /listens?after=<seq>&limit=<n>` ascending by `seq`. Each item is a `listen` value plus `seq`. NDJSON when `Accept: application/x-ndjson`, else `{"listens": […], "more": <bool>, "head": <int>}`.

### 6.4 Other
`GET /sync/entity?kind=&id=` returns one entity. `PUT /blobs/{sha256}` stores an image up to 2 MiB (`image/jpeg`, `image/png`, `image/webp`; the hash is checked) whose header declares at most 16 megapixels and 8192 pixels on a side, and at most 50 MB per user in all (`413 too_large` otherwise); `GET /blobs/{sha256}` returns it. The daily tidy deletes blobs that no playlist names as its cover once their newest upload is a week old.

## 7. Position keys

Keys are non-empty strings over the alphabet `0-9A-Za-z` (62 digits, ordered), never ending in `0`. `between(a, b)` returns a key strictly between `a` and `b` (`a` may be absent for "before everything", `b` for "after everything"; both absent returns `"V"`). The algorithm is the digit-wise midpoint used by the `fractional-indexing` family: find the longest common prefix (the shorter key padded with `0`), then pick the midpoint digit, descending a digit when the gap is one. When one bound is absent the digit next to the other bound is taken instead (`a + 1` after everything, `b - 1` before everything), so appending or prepending costs one character per about 30 keys. When `a >= b` the result is just after `a`. The core crate is the single implementation; its tests include 10,000 random insertions at random places and require strict order, uniqueness of `(pos, id)`, and that appending 1,000 times never exceeds 64 characters before the rewrite rule triggers.

## 8. The listen ledger

For every second `t` the server keeps all events with `ts = t`. The visible set is computed as a function of the whole set:

The events of a second carry the `titleKey` and `artistKey` the server stored with them.

1. Sort events by `(priority, eventId)`; priority 0 is `recorded = true`, 1 is everything else.
2. Walk in order, keeping an event unless (a) a kept event has the same `titleKey` (the title key is derived from `ref.title`/`ref.artist` through the shared normalizer), or (b) the event is not recorded and a kept recorded event has the same `artistKey`.
3. Every event not kept has `suppressed = true`; every kept event has `suppressed = false`.

After each `listen.record` that touches second `t`, the server recomputes `t` and emits a change for each event whose `suppressed` flag changed. Rows are never deleted.

## 9. Live channel (version 1 subset)

`GET /live` upgrades to a WebSocket. It needs `Authorization: Bearer <device token>` on the upgrade request (an API key, a pending user and any request with an `Origin` header are refused before the upgrade, with the usual error bodies). Frames are JSON text, at most 64 KiB; a larger frame closes the socket with code 1009.

Server to client:
- `{"t":"poke","head":<seq>}` after a commit that changes the caller's scope (the user's own entities or `household`). Bursts are coalesced into one poke carrying the highest `head`. A poke is a hint to pull, never data; a client that connects pulls once itself.
- `{"t":"presence","device","state","ref","positionMs","at"}`: another device of the same user. The latest frame of each device is kept in memory and replayed to a new connection. When a device's last socket closes the server relays `state: "offline"` for it and forgets its presence.
- `{"t":"command","id","from","name","args","sentAt"}`: a command from another device of the same user. `id` is fresh, `from` is the sender's device id and `sentAt` is the server's clock in Unix milliseconds.
- `{"t":"error","code","message"}`: `target_offline` (the target has no open socket, or is not a device of the caller's user; commands are never queued), `rate_limited` (more than 5 commands per second from the device), `bad_frame` (not a JSON object with a known `t`, or a missing field), `internal`.

Client to server:
- `{"t":"presence","state":"playing","ref":…,"positionMs":…}`: `state` is a word of up to 32 characters. The server ignores any `device` and `at` in it, uses the device of the token and its own clock, and relays the frame to the user's other devices.
- `{"t":"command","to":"<device id>","name":"<up to 64 characters>","args":{…}}`.

Liveness: the server sends a WebSocket ping every 25 seconds, and closes (code 1000) a connection from which it has heard nothing, pongs included, for 75 seconds. It checks the token again every 30 seconds and before relaying every command; a revoked token, or a user whose role became `pending`, closes the socket with code 1008. A stopping server closes every socket with code 1001 (going away).

## 10. Storage

Three SQLite files in the data directory, WAL mode, one writer thread each. `security.sqlite` and `state.sqlite` use `synchronous = FULL`, and on macOS also `fullfsync` and `checkpoint_fullfsync`, because macOS `fsync` stops at the drive's cache and only `F_FULLFSYNC` makes a commit survive power loss (a commit costs about 16 ms there instead of 2 ms); `library.sqlite` uses `NORMAL`.

### 10.1 `security.sqlite`
```
users(id TEXT PRIMARY KEY, name TEXT NOT NULL, tailnet_user_id TEXT, login TEXT, role TEXT NOT NULL, created_at INTEGER NOT NULL)
devices(id TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id), name TEXT NOT NULL, platform TEXT NOT NULL,
        token_hash BLOB NOT NULL UNIQUE, created_at INTEGER NOT NULL, last_seen_at INTEGER, revoked_at INTEGER)
enrollments(code_hash BLOB PRIMARY KEY, user_id TEXT NOT NULL, created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL, used_at INTEGER)
api_keys(id TEXT PRIMARY KEY, user_id TEXT NOT NULL, name TEXT NOT NULL, key_hash BLOB NOT NULL UNIQUE, created_at INTEGER NOT NULL, revoked_at INTEGER)
audit(seq INTEGER PRIMARY KEY AUTOINCREMENT, at INTEGER NOT NULL, actor TEXT, action TEXT NOT NULL, detail TEXT, prev_hash BLOB NOT NULL, hash BLOB NOT NULL)
server_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL)   -- incarnation, server_id, schema
lastfm_sessions(user_id TEXT PRIMARY KEY, username TEXT NOT NULL, session_key TEXT NOT NULL)
```
Tokens and keys are stored as SHA-256. `audit.hash = SHA-256(prev_hash || at || actor || action || detail)`.

### 10.2 `state.sqlite`
```
server_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL)        -- seq counter, server_hlc, schema
changes(seq INTEGER NOT NULL, scope TEXT NOT NULL, kind TEXT NOT NULL, id TEXT NOT NULL, PRIMARY KEY(scope, kind, id)); CREATE INDEX changes_seq ON changes(seq)
playlists(id TEXT PRIMARY KEY, owner TEXT NOT NULL, name TEXT NOT NULL, cover_blob TEXT, visibility TEXT NOT NULL, alive INTEGER NOT NULL,
          created_at INTEGER NOT NULL, st_name INTEGER NOT NULL, st_cover INTEGER NOT NULL, st_visibility INTEGER NOT NULL, st_alive INTEGER NOT NULL)
playlist_entries(id TEXT PRIMARY KEY, playlist_id TEXT NOT NULL, ref_json TEXT NOT NULL, pos TEXT NOT NULL, alive INTEGER NOT NULL,
                 st_ref INTEGER NOT NULL, st_pos INTEGER NOT NULL, st_alive INTEGER NOT NULL); CREATE INDEX entries_playlist ON playlist_entries(playlist_id, pos, id)
loves(user_id TEXT NOT NULL, song_key TEXT NOT NULL, ref_json TEXT NOT NULL, loved INTEGER NOT NULL, stamp INTEGER NOT NULL, PRIMARY KEY(user_id, song_key))
ratings(user_id TEXT NOT NULL, song_key TEXT NOT NULL, ref_json TEXT NOT NULL, rating INTEGER, stamp INTEGER NOT NULL, PRIMARY KEY(user_id, song_key))
scalars(user_id TEXT NOT NULL, key TEXT NOT NULL, value_json TEXT NOT NULL, deleted INTEGER NOT NULL, stamp INTEGER NOT NULL, PRIMARY KEY(user_id, key))
sessions(user_id TEXT NOT NULL, device_id TEXT NOT NULL, session_json TEXT NOT NULL, stamp INTEGER NOT NULL, PRIMARY KEY(user_id, device_id))
listens(event_id TEXT NOT NULL, user_id TEXT NOT NULL, ts INTEGER NOT NULL, song_key TEXT NOT NULL, title_key TEXT NOT NULL, artist_key TEXT NOT NULL,
        ref_json TEXT NOT NULL, played_s INTEGER NOT NULL, source TEXT NOT NULL, recorded INTEGER NOT NULL, device_id TEXT, suppressed INTEGER NOT NULL, seq INTEGER NOT NULL,
        PRIMARY KEY(user_id, event_id))
         -- indexes: (user_id, ts), (user_id, seq), (user_id, song_key, ts)
device_progress(device_id TEXT NOT NULL, instance TEXT NOT NULL, last_mutation_id INTEGER NOT NULL, PRIMARY KEY(device_id, instance))
mutation_results(device_id TEXT NOT NULL, instance TEXT NOT NULL, id INTEGER NOT NULL, arg_hash BLOB NOT NULL, status TEXT NOT NULL, code TEXT, at INTEGER NOT NULL, PRIMARY KEY(device_id, instance, id))
blobs(hash TEXT PRIMARY KEY, mime TEXT NOT NULL, size INTEGER NOT NULL, data BLOB NOT NULL)
blob_uploads(user_id TEXT NOT NULL, hash TEXT NOT NULL, uploaded_at INTEGER NOT NULL, PRIMARY KEY(user_id, hash))
rest_progress(key_id TEXT PRIMARY KEY, last_mutation_id INTEGER NOT NULL)
```
`scope` is the user id, or `household` for household playlists and their entries.

`rest_progress` numbers the writes of the OpenSubsonic API. Each API key (and the legacy password login) writes as a device of its own whose id is the key's id and whose name is `opensubsonic:<key name>`, platform `other`; the key's mutations are the ones of section 5, applied server side with ids from this counter and stamps from the server clock, without an `instance` or a `mutation_results` row. A scrobble becomes `listen.record` with `source = opensubsonic` and the `eventId` of `event_id_rec(device, "rest", counter)`. A saved play queue is the key's `session`. The import of the single-user server's data (`legacy_migrated` in `server_meta`) writes as the device `legacy` with the ids and the import floor of section 13.

## 11. Limits

Mutation batch ≤ 500; request body ≤ 1 MiB (blobs ≤ 2 MiB); a scalar value ≤ 64 KiB; a playlist ≤ 20,000 alive entries and 40,000 in all, dead ones included; a `state.reseed` ≤ 1,000 entities and 400 KB; a picture ≤ 16 megapixels and 8192 pixels a side; blobs ≤ 50 MB per user; at most 512 connections, 64 per source address, a request head within 10 s and 75 s idle between requests; `limit` ≤ 5000; WebSocket frame ≤ 64 KiB. Over a limit: `413 too_large` or `429 rate_limited` with `Retry-After`.

Refusals that wait on the server, not on the client, both carrying `Retry-After` and leaving all state untouched: `503 clock_behind` (section 1.1) when the wall clock is more than an hour behind `server_hlc`, and `507 insufficient_storage` when SQLite reports the disk full on a write (`SQLITE_FULL`) in any database, including enrollment and device changes. A client keeps its queue, shows the server's state to the person ("The clock on arch is wrong" or "arch is out of disk space", `docs/server/UX.md` section 4) and tries again by itself; it never treats either as a reason to drop mutations or reset.

## 12. Corpus format

`linux/server-core/tests/corpus/*.json`: `{"name", "steps": [ {"actor": "server|<client name>", "op": "push|pull|offline|online|crash|restore", "mutations": […], "stampOffsetMs": 0} ], "expect": {"server": {…entities…}, "clients": {"<name>": {…visible entities…}}}}`. The Rust test runner replays every file against the in-process server and clients and compares canonical JSON. Swift binding tests replay a subset through the UniFFI functions.

## 13. Deterministic ids and the import floor

Playlists and entries that existed before a device first connected get ids every device derives identically, so two devices connecting at once converge with no coordination. The one implementation is `flaccy_server_core::song::{normalize_playlist_name, playlist_id, entry_id}`; Apple clients call it through the binding and must never re-implement it.

- `playlist_id(name, occurrence)`: `occurrence` is 0 for the first playlist with that normalized name on the device (ordered by creation date, then local id), 1 for the next, and so on. Only occurrence 0 is ever auto-merged across devices; every later same-named playlist keeps a fresh UUIDv7.
- `entry_id(playlistId, songKey, occurrence)`: `occurrence` is 0 for the first entry of that song in the playlist by position, 1 for the next.
- Loves, ratings and other scalars that exist before the first connect are emitted with the import floor stamp `Stamp::from_wall_ms(1_577_836_800_000)` (2020-01-01T00:00:00Z, counter 0), so any real action wins over an imported one.
- Listens that exist before the first connect are sent as `listen.record` batches of 500 with `source = migrated` and the ids of `event_id_mig`.
