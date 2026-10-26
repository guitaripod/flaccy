//! Applying mutations to in-memory state under the semantics of PROTOCOL.md
//! section 5. Every function leaves its state untouched when it answers
//! [`Status::Invalid`], and answers [`Status::Noop`] when the write changes
//! nothing, so applying a mutation twice is harmless.

mod merge;
mod playlist;
mod singles;

pub use merge::{reseed_into_doc, upsert, Mergeable};
pub use playlist::apply_playlist;
pub use singles::{apply_love, apply_rating, apply_scalar, apply_session};

use crate::model::EntityKind;
use crate::wire::{ErrorCode, MutationStatus, Role};
use serde::{Deserialize, Serialize};

/// Who is writing: the identity the server resolved from the device token.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Caller {
    /// The user id.
    pub user: String,
    /// The caller's role.
    pub role: Role,
    /// The device the write came from.
    #[serde(default)]
    pub device: String,
}

impl Caller {
    /// A member writing from a device.
    pub fn member(user: &str, device: &str) -> Self {
        Caller {
            user: user.to_owned(),
            role: Role::Member,
            device: device.to_owned(),
        }
    }

    /// True for admins and members; guests and pending devices write nothing.
    pub fn can_write(&self) -> bool {
        matches!(self.role, Role::Admin | Role::Member)
    }

    /// True for an admin.
    pub fn is_admin(&self) -> bool {
        self.role == Role::Admin
    }
}

/// The verdict on one mutation.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Status {
    /// The write changed state.
    Applied,
    /// Valid, but changed nothing.
    Noop,
    /// Refused with this code.
    Invalid(ErrorCode),
    /// An operation this build does not know.
    Unsupported,
}

impl Status {
    /// The wire status and, for `invalid`, its code.
    pub fn wire(self) -> (MutationStatus, Option<ErrorCode>) {
        match self {
            Status::Applied => (MutationStatus::Applied, None),
            Status::Noop => (MutationStatus::Noop, None),
            Status::Invalid(code) => (MutationStatus::Invalid, Some(code)),
            Status::Unsupported => (MutationStatus::Unsupported, None),
        }
    }
}

/// An entity a mutation changed, for the server to write into `changes`.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct EntityRef {
    /// The kind of entity.
    pub kind: EntityKind,
    /// The entity's id.
    pub id: String,
}

impl EntityRef {
    /// A reference to the entity of this kind and id.
    pub fn new(kind: EntityKind, id: &str) -> Self {
        EntityRef {
            kind,
            id: id.to_owned(),
        }
    }
}

/// The status plus every entity the mutation changed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Outcome {
    /// What the mutation did.
    pub status: Status,
    /// The entities the write changed.
    pub changed: Vec<EntityRef>,
}

impl Outcome {
    /// Applied when anything changed, otherwise a noop.
    pub fn from_changed(changed: Vec<EntityRef>) -> Self {
        let status = if changed.is_empty() {
            Status::Noop
        } else {
            Status::Applied
        };
        Outcome { status, changed }
    }

    /// Valid but changing nothing.
    pub fn noop() -> Self {
        Outcome::from_changed(Vec::new())
    }

    /// Refused with a code; nothing changed.
    pub fn invalid(code: ErrorCode) -> Self {
        Outcome {
            status: Status::Invalid(code),
            changed: Vec::new(),
        }
    }

    /// An operation this build does not know; nothing changed.
    pub fn unsupported() -> Self {
        Outcome {
            status: Status::Unsupported,
            changed: Vec::new(),
        }
    }
}
