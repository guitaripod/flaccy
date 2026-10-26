//! Playlist and entry operations on one [`PlaylistDoc`].

use super::merge::assign;
use super::{Caller, EntityRef, Outcome};
use crate::model::{
    EntityKind, Entry, Place, Playlist, PlaylistDoc, PlaylistStamps, Visibility, MAX_ENTRIES,
    MAX_TOTAL_ENTRIES,
};
use crate::mutation::{
    CreateArgs, InsertArgs, InsertManyArgs, MoveArgs, NewEntry, PlaylistOp, Target,
};
use crate::position::{between, needs_rebalance, rebalance};
use crate::stamp::Stamp;
use crate::wire::ErrorCode;
use std::collections::HashSet;

type Changes = Vec<EntityRef>;

/// True when the caller may edit the playlist's name and entries: its owner, or anyone on a household playlist.
pub(super) fn can_edit_content(playlist: &Playlist, caller: &Caller) -> bool {
    playlist.owner == caller.user || playlist.visibility == Visibility::Household
}

fn can_administer(playlist: &Playlist, caller: &Caller) -> bool {
    playlist.owner == caller.user
        || (caller.is_admin() && playlist.visibility == Visibility::Household)
}

fn owner_only(op: &PlaylistOp) -> bool {
    matches!(
        op,
        PlaylistOp::SetCover(_)
            | PlaylistOp::ClearCover(_)
            | PlaylistOp::Delete(_)
            | PlaylistOp::Restore(_)
            | PlaylistOp::SetVisibility(_)
    )
}

fn touches_entries(op: &PlaylistOp) -> bool {
    matches!(
        op,
        PlaylistOp::Insert(_) | PlaylistOp::InsertMany(_) | PlaylistOp::Move(_)
    )
}

fn missing_code(op: &PlaylistOp) -> ErrorCode {
    match op.target() {
        Target::Entry(_) => ErrorCode::UnknownAnchor,
        _ => ErrorCode::UnknownPlaylist,
    }
}

fn addresses(op: &PlaylistOp, doc: &PlaylistDoc) -> bool {
    match op.target() {
        Target::Playlist(id) => id == doc.playlist.id,
        _ => true,
    }
}

/// Applies a playlist or entry operation.
///
/// `doc` is the playlist the operation addresses (for `entry.move` and
/// `entry.remove`, the playlist holding that entry), or `None` when it does not
/// exist; only `playlist.create` fills it in.
pub fn apply_playlist(
    doc: &mut Option<PlaylistDoc>,
    op: &PlaylistOp,
    caller: &Caller,
    stamp: Stamp,
) -> Outcome {
    if !caller.can_write() {
        return Outcome::invalid(ErrorCode::Forbidden);
    }
    if let PlaylistOp::Create(args) = op {
        return create(doc, args, caller, stamp);
    }
    let Some(target) = doc.as_mut() else {
        return Outcome::invalid(missing_code(op));
    };
    if !addresses(op, target) {
        return Outcome::invalid(ErrorCode::BadArgs);
    }
    let allowed = if owner_only(op) {
        can_administer(&target.playlist, caller)
    } else {
        can_edit_content(&target.playlist, caller)
    };
    if !allowed {
        return Outcome::invalid(ErrorCode::Forbidden);
    }
    let mut changed = Vec::new();
    if let Err(code) = edit(target, op, stamp, &mut changed) {
        return Outcome::invalid(code);
    }
    if touches_entries(op) {
        rebalance_overlong(target, &mut changed);
    }
    Outcome::from_changed(changed)
}

fn create(
    doc: &mut Option<PlaylistDoc>,
    args: &CreateArgs,
    caller: &Caller,
    stamp: Stamp,
) -> Outcome {
    if let Some(existing) = doc.as_ref() {
        return if existing.playlist.owner == caller.user {
            Outcome::noop()
        } else {
            Outcome::invalid(ErrorCode::Forbidden)
        };
    }
    let playlist = Playlist {
        id: args.id.clone(),
        owner: caller.user.clone(),
        name: args.name.clone(),
        cover_blob: None,
        visibility: Visibility::Private,
        alive: true,
        created_at: stamp.wall_ms() / 1000,
        stamps: PlaylistStamps::all(stamp),
    };
    let mut created = PlaylistDoc::new(playlist);
    let mut changed = vec![EntityRef::new(EntityKind::Playlist, &args.id)];
    append_all(
        &mut created,
        &args.entries,
        &Place::Last,
        stamp,
        &mut changed,
    );
    rebalance_overlong(&mut created, &mut changed);
    *doc = Some(created);
    Outcome::from_changed(changed)
}

fn edit(
    doc: &mut PlaylistDoc,
    op: &PlaylistOp,
    stamp: Stamp,
    changed: &mut Changes,
) -> Result<(), ErrorCode> {
    match op {
        PlaylistOp::Create(_) => {}
        PlaylistOp::Rename(args) => write_playlist(doc, changed, |p| {
            assign(&mut p.name, &mut p.stamps.name, args.name.clone(), stamp)
        }),
        PlaylistOp::SetCover(args) => set_cover(doc, Some(args.blob.clone()), stamp, changed),
        PlaylistOp::ClearCover(_) => set_cover(doc, None, stamp, changed),
        PlaylistOp::Delete(_) => set_alive(doc, false, stamp, changed),
        PlaylistOp::Restore(_) => set_alive(doc, true, stamp, changed),
        PlaylistOp::SetVisibility(args) => write_playlist(doc, changed, |p| {
            assign(
                &mut p.visibility,
                &mut p.stamps.visibility,
                args.visibility,
                stamp,
            )
        }),
        PlaylistOp::Insert(args) => insert(doc, args, stamp, changed)?,
        PlaylistOp::InsertMany(args) => insert_many(doc, args, stamp, changed)?,
        PlaylistOp::Move(args) => move_entry(doc, args, stamp, changed)?,
        PlaylistOp::Remove(args) => remove_entry(doc, &args.id, stamp, changed)?,
    }
    Ok(())
}

fn write_playlist(
    doc: &mut PlaylistDoc,
    changed: &mut Changes,
    write: impl FnOnce(&mut Playlist) -> bool,
) {
    if write(&mut doc.playlist) {
        changed.push(EntityRef::new(EntityKind::Playlist, &doc.playlist.id));
    }
}

fn set_cover(doc: &mut PlaylistDoc, blob: Option<String>, stamp: Stamp, changed: &mut Changes) {
    write_playlist(doc, changed, |p| {
        assign(&mut p.cover_blob, &mut p.stamps.cover, blob, stamp)
    });
}

fn set_alive(doc: &mut PlaylistDoc, alive: bool, stamp: Stamp, changed: &mut Changes) {
    write_playlist(doc, changed, |p| {
        assign(&mut p.alive, &mut p.stamps.alive, alive, stamp)
    });
}

fn position_between(prev: Option<&Entry>, next: Option<&Entry>) -> String {
    between(
        prev.map(|entry| entry.pos.as_str()),
        next.map(|entry| entry.pos.as_str()),
    )
}

fn place_entry(
    doc: &mut PlaylistDoc,
    new: &NewEntry,
    place: &Place,
    stamp: Stamp,
    changed: &mut Changes,
) -> Result<(), ErrorCode> {
    let (prev, next) = doc.neighbours(place, None)?;
    let pos = position_between(prev, next);
    doc.entries.push(Entry::new(
        &new.id,
        &doc.playlist.id,
        new.song.clone(),
        pos,
        stamp,
    ));
    changed.push(EntityRef::new(EntityKind::PlaylistEntry, &new.id));
    Ok(())
}

/// A stretch of new entries going between two neighbours: no other entry lies between them, so the next
/// entry of the stretch needs no search.
struct Run {
    prev: Option<String>,
    next: Option<String>,
}

impl Run {
    fn starting_at(doc: &PlaylistDoc, place: &Place) -> Option<Run> {
        let (prev, next) = doc.neighbours(place, None).ok()?;
        Some(Run {
            prev: prev.map(|entry| entry.pos.clone()),
            next: next.map(|entry| entry.pos.clone()),
        })
    }

    fn place(self, doc: &mut PlaylistDoc, new: &NewEntry, stamp: Stamp, changed: &mut Changes) -> Option<Run> {
        let pos = between(self.prev.as_deref(), self.next.as_deref());
        let stays_between = self.next.as_deref().is_none_or(|next| pos.as_str() < next);
        doc.entries.push(Entry::new(&new.id, &doc.playlist.id, new.song.clone(), pos.clone(), stamp));
        changed.push(EntityRef::new(EntityKind::PlaylistEntry, &new.id));
        stays_between.then_some(Run { prev: Some(pos), next: self.next })
    }
}

/// Places `entries` one after the other starting at `first_place`.
///
/// The neighbours are found once; each entry then takes the key between the last one and the same next
/// neighbour, which is where a search after it would put it. Keys that fail to stay in order, which only
/// equal keys left by a reseed can cause, fall back to a search per entry.
fn append_all(
    doc: &mut PlaylistDoc,
    entries: &[NewEntry],
    first_place: &Place,
    stamp: Stamp,
    changed: &mut Changes,
) {
    let mut place = first_place.clone();
    let mut run = Run::starting_at(doc, first_place);
    for new in entries {
        match run.take() {
            Some(current) => {
                run = current.place(doc, new, stamp, changed);
                place = Place::After { id: new.id.clone() };
            }
            None => {
                if place_entry(doc, new, &place, stamp, changed).is_ok() {
                    place = Place::After { id: new.id.clone() };
                }
            }
        }
    }
}

/// Refuses growth past the entry limits: [`MAX_ENTRIES`] alive and [`MAX_TOTAL_ENTRIES`] with the dead ones,
/// which are kept forever as tombstones.
fn check_capacity(doc: &PlaylistDoc, extra: usize) -> Result<(), ErrorCode> {
    let alive = doc.entries.iter().filter(|entry| entry.alive).count();
    if alive + extra > MAX_ENTRIES || doc.entries.len() + extra > MAX_TOTAL_ENTRIES {
        Err(ErrorCode::TooLarge)
    } else {
        Ok(())
    }
}

fn insert(
    doc: &mut PlaylistDoc,
    args: &InsertArgs,
    stamp: Stamp,
    changed: &mut Changes,
) -> Result<(), ErrorCode> {
    if doc.entry(&args.id).is_some() {
        return Ok(());
    }
    check_capacity(doc, 1)?;
    let new = NewEntry {
        id: args.id.clone(),
        song: args.song.clone(),
    };
    place_entry(doc, &new, &args.place, stamp, changed)
}

fn insert_many(
    doc: &mut PlaylistDoc,
    args: &InsertManyArgs,
    stamp: Stamp,
    changed: &mut Changes,
) -> Result<(), ErrorCode> {
    let present: HashSet<&str> = doc.entries.iter().map(|entry| entry.id.as_str()).collect();
    if args.entries.iter().any(|new| present.contains(new.id.as_str())) {
        return Ok(());
    }
    check_capacity(doc, args.entries.len())?;
    doc.neighbours(&args.place, None)?;
    append_all(doc, &args.entries, &args.place, stamp, changed);
    Ok(())
}

fn move_entry(
    doc: &mut PlaylistDoc,
    args: &MoveArgs,
    stamp: Stamp,
    changed: &mut Changes,
) -> Result<(), ErrorCode> {
    let current = doc.entry(&args.id).ok_or(ErrorCode::UnknownAnchor)?;
    if stamp < current.stamps.pos {
        return Ok(());
    }
    let (prev, next) = doc.neighbours(&args.place, Some(&args.id))?;
    let pos = if sits_between(current, prev, next) {
        current.pos.clone()
    } else {
        position_between(prev, next)
    };
    if let Some(entry) = doc.entries.iter_mut().find(|entry| entry.id == args.id) {
        if assign(&mut entry.pos, &mut entry.stamps.pos, pos, stamp) {
            changed.push(EntityRef::new(EntityKind::PlaylistEntry, &entry.id));
        }
    }
    Ok(())
}

fn order_key(entry: &Entry) -> (&str, &str) {
    (entry.pos.as_str(), entry.id.as_str())
}

fn sits_between(entry: &Entry, prev: Option<&Entry>, next: Option<&Entry>) -> bool {
    prev.is_none_or(|prev| order_key(prev) < order_key(entry))
        && next.is_none_or(|next| order_key(entry) < order_key(next))
}

fn remove_entry(
    doc: &mut PlaylistDoc,
    id: &str,
    stamp: Stamp,
    changed: &mut Changes,
) -> Result<(), ErrorCode> {
    let entry = doc
        .entries
        .iter_mut()
        .find(|entry| entry.id == id)
        .ok_or(ErrorCode::UnknownAnchor)?;
    let newer = entry.stamps.alive.max(stamp);
    if entry.alive || newer != entry.stamps.alive {
        entry.alive = false;
        entry.stamps.alive = newer;
        changed.push(EntityRef::new(EntityKind::PlaylistEntry, id));
    }
    Ok(())
}

fn rebalance_overlong(doc: &mut PlaylistDoc, changed: &mut Changes) {
    if !doc.entries.iter().any(|entry| needs_rebalance(&entry.pos)) {
        return;
    }
    let mut order: Vec<usize> = (0..doc.entries.len()).collect();
    order.sort_by(|&a, &b| {
        let (a, b) = (&doc.entries[a], &doc.entries[b]);
        a.pos.cmp(&b.pos).then_with(|| a.id.cmp(&b.id))
    });
    let known: HashSet<String> = changed.iter().map(|c| c.id.clone()).collect();
    for (index, key) in order.into_iter().zip(rebalance(doc.entries.len())) {
        let entry = &mut doc.entries[index];
        if entry.pos != key {
            entry.pos = key;
            if !known.contains(&entry.id) {
                changed.push(EntityRef::new(EntityKind::PlaylistEntry, &entry.id));
            }
        }
    }
}
