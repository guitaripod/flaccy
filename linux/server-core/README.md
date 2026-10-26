# flaccy-server-core

Flaccy Server's sync engine as pure logic (no I/O, database, async or threads). The SQLite server, the Linux client and, through `json_api`, the Apple clients run the same code. The contract is `docs/server/PROTOCOL.md`. Features: `sim` compiles the simulator for other crates' tests.

## stamp
- `Stamp::{pack, unpack, wall_ms, from_wall_ms}`: `(wall_ms << 16) | counter`, ordered as an integer.
- `ClientClock::{new(last, offset), next(now), observe_server_time(server, local_now), last, offset_ms}`: `max(last + 1, (now + offset) << 16)`; persist `last()` with the write it stamped.
- `ServerClock::{new(last), next(now), store(client_stamp, now), is_behind(now), last}`: `store` is `min(client, next)`; `is_behind` means answer `503 clock_behind`.

## song
- `song_key(artist_key, title_key)`, `is_song_key`, `is_event_id`.
- `event_id_rec(device, instance, counter)`, `event_id_lfm(account, ts, song_key)`, `event_id_mig(ts, title_key, artist_key)`.

## position
- `between(a, b)`: key strictly between two keys, either may be `None`. `rebalance(n)`: `n` even keys. `needs_rebalance(pos)` (> `MAX_POS_LEN` = 64), `is_valid(pos)`.

## model, wire
- Entities: `SongRef`, `Playlist`, `Entry`, `PlaylistDoc {playlist, entries}` (`ordered`, `visible`, `entry`, `neighbours`), `Love`, `Rating`, `Scalar`, `SessionDoc`, `Listen`, `Place`, `Visibility`, `Source`, `Entity {kind, id, value}`, `EntityValue` (decoded and validated by `Entity::decode`).
- Envelopes: `Mutation`, `MutationResult`, `MutationStatus`, `ErrorCode`, `PushRequest`, `PushResponse`, `Change`, `PullResponse`, `Hello`, `Role`. All camelCase on the wire.
- `scalar::{validate_scalar_key, validate_scalar}`: key prefix rules and size limits.

## mutation
- `parse(&Mutation) -> Result<Op, ParseError>`: unknown name is `Unsupported`, bad arguments are `Invalid(code)`. Every argument check that needs no stored state happens here.
- `Op::target() -> Target`: what to load before applying (`Playlist(id)`, `Entry(id)` for move and remove, `Love(songKey)`, `Rating`, `Scalar(key)`, `Session`, `Listens`, `Device`, `Reseed`).

## apply
- `apply_playlist(&mut Option<PlaylistDoc>, &PlaylistOp, &Caller, stored_stamp) -> Outcome`: all `playlist.*` and `entry.*`; the doc is the playlist (for move and remove the one holding the entry), `None` if absent. Rewrites every `pos` past 64 characters and reports each entry.
- `apply_love`, `apply_rating`, `apply_scalar`, `apply_session(&mut Option<T>, args, &Caller, stamp)`; `upsert` and `reseed_into_doc` for `state.reseed` (one playlist at a time).
- `Outcome {status: Status, changed: Vec<EntityRef>}`; `Status` is `Applied`, `Noop`, `Invalid(code)` or `Unsupported`; `status.wire()` gives the wire pair. `Invalid` leaves state untouched; write back only `changed`.
- `Caller {user, role, device}`. Uniqueness of entry ids across playlists, listens, `device.rename` and transactions across the entities of one `state.reseed` are the server's.

## ledger
- `suppressed_flags(&[SecondEvent]) -> Vec<bool>` and `recompute_second(&[SecondEvent]) -> Vec<FlagChange>`: PROTOCOL section 8, independent of event order. Events carry the title and artist keys the normalizer made.

## rebase
- `PendingMutation {mutation, failed}` (`mutation.stamp` is the local stamp).
- `fold_playlist(id, base, &Caller, pending)`, `fold_love`, `fold_rating`, `fold_scalar`, `fold_session`: base plus live pending mutations, by the same apply code. Pass the whole pending list; unrelated mutations are ignored.

## digest
- `canonical_json(&Value)`, `arg_hash(name, args)` (the push retry check), `state_digest(&[Entity])`.

## json_api (string in, string out, for UniFFI)
- `apply_playlist`, `apply_scalar`, `rebase_playlist`, `between`, `song_key`, `suppressed_flags`, `next_stamp`. Each takes one JSON document and answers one; a failure is `{"error": "..."}`. Shapes are in the doc comments.

## sim (tests and `--features sim`)
- `sim::server::ServerModel` (push, pull, snapshot, restore), `sim::client::ClientModel` (record, visible, push_request, on_push_response, on_pull_response), `sim::world::run_seed(seed)`. `cargo test -p flaccy-server-core` runs 300 seeds; `SIM_SEEDS=20000 cargo test --release -p flaccy-server-core -- --ignored sim_long` runs more.
