//! Single-entity writes: loves, ratings, scalars and sessions, each a
//! last-writer upsert of one entity.

use super::merge::upsert;
use super::{Caller, Outcome};
use crate::model::{Love, Rating, Scalar, SessionDoc};
use crate::mutation::{session_entity, LoveSet, RatingSet, ScalarOp};
use crate::stamp::Stamp;
use serde_json::Value;

/// `love.set` at the stored stamp.
pub fn apply_love(
    slot: &mut Option<Love>,
    args: &LoveSet,
    caller: &Caller,
    stamp: Stamp,
) -> Outcome {
    upsert(slot, args.entity(stamp), caller)
}

/// `rating.set` at the stored stamp.
pub fn apply_rating(
    slot: &mut Option<Rating>,
    args: &RatingSet,
    caller: &Caller,
    stamp: Stamp,
) -> Outcome {
    upsert(slot, args.entity(stamp), caller)
}

/// `scalar.set` and `scalar.clear` at the stored stamp.
pub fn apply_scalar(
    slot: &mut Option<Scalar>,
    op: &ScalarOp,
    caller: &Caller,
    stamp: Stamp,
) -> Outcome {
    upsert(slot, op.entity(stamp), caller)
}

/// `session.save`: writes the caller device's session at the stored stamp.
pub fn apply_session(
    slot: &mut Option<SessionDoc>,
    session: &Value,
    caller: &Caller,
    stamp: Stamp,
) -> Outcome {
    upsert(slot, session_entity(&caller.device, session, stamp), caller)
}
