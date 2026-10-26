//! The wire envelopes of `docs/server/PROTOCOL.md`, camelCase on the wire.

use crate::model::EntityKind;
use crate::stamp::Stamp;
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Why a mutation was refused (`invalid` results carry one).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ErrorCode {
    /// The playlist does not exist.
    UnknownPlaylist,
    /// The anchor or addressed entry does not exist.
    UnknownAnchor,
    /// The arguments are missing or malformed.
    BadArgs,
    /// The key or song key is not allowed.
    BadKey,
    /// The caller may not write this.
    Forbidden,
    /// A size limit was exceeded.
    TooLarge,
}

/// What a mutation did, as the push response reports it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MutationStatus {
    /// The write changed state.
    Applied,
    /// Valid, but changed nothing.
    Noop,
    /// Refused; the result carries a code.
    Invalid,
    /// An operation this build does not know.
    Unsupported,
}

/// A caller's standing on the server.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Role {
    /// Runs the server.
    Admin,
    /// A full user.
    Member,
    /// Read only.
    Guest,
    /// A device not yet approved.
    Pending,
}

/// One client write: a dense per-instance id, a stamp, a name and its arguments.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Mutation {
    /// The dense per-instance mutation id.
    pub id: i64,
    /// The operation name, such as `playlist.rename`.
    pub name: String,
    /// The client stamp.
    pub stamp: Stamp,
    /// The operation's arguments.
    #[serde(default)]
    pub args: Value,
}

/// The server's answer to one mutation.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct MutationResult {
    /// The mutation id answered.
    pub id: i64,
    /// What the mutation did.
    pub status: MutationStatus,
    /// Why an `invalid` result was refused.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub code: Option<ErrorCode>,
}

/// `POST /sync/push` request body.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct PushRequest {
    /// The device id.
    pub device: String,
    /// The client install's instance id; mutation ids are dense within it.
    pub instance: String,
    /// The mutations, ids ascending.
    pub mutations: Vec<Mutation>,
}

/// `POST /sync/push` response body.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PushResponse {
    /// One result per mutation, in order.
    pub results: Vec<MutationResult>,
    /// The server's wall clock in milliseconds, for offset alignment.
    pub server_time_ms: i64,
}

/// One entry of a pull: an entity's full current value at a sequence number.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Change {
    /// The change sequence number.
    pub seq: i64,
    /// The kind of entity.
    pub kind: EntityKind,
    /// The entity's id.
    pub id: String,
    /// True when the entity is dead.
    pub deleted: bool,
    /// The entity's JSON value.
    pub value: Value,
}

/// `GET /sync/pull` response body.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PullResponse {
    /// The highest change sequence number in scope.
    pub head: i64,
    /// The server incarnation the state belongs to.
    pub incarnation: String,
    /// The highest mutation id applied for the caller's device and instance.
    pub last_mutation_id: i64,
    /// True when another page follows.
    pub more: bool,
    /// The server's wall clock in milliseconds, for offset alignment.
    pub server_time_ms: i64,
    /// The changed entities, ascending by `seq`.
    pub changes: Vec<Change>,
}

/// The server block of `GET /hello`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ServerInfo {
    /// The server's name.
    pub name: String,
    /// The server version.
    pub version: String,
    /// The storage schema version.
    pub schema: u32,
}

/// The caller block of `GET /hello`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct HelloCaller {
    /// The user id.
    pub user: String,
    /// The caller's role.
    pub role: Role,
    /// The caller's device id, if any.
    pub device: Option<String>,
}

/// `GET /hello` response body.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Hello {
    /// The protocol versions the server speaks.
    pub protocol: Vec<u32>,
    /// The server's identity.
    pub server: ServerInfo,
    /// What this build implements.
    pub features: Vec<String>,
    /// The reachability mode, `easy` or `household`.
    pub mode: String,
    /// The server's wall clock in milliseconds, for offset alignment.
    pub server_time_ms: i64,
    /// The server incarnation the state belongs to.
    pub incarnation: String,
    /// Who the token belongs to, when one was sent.
    pub caller: Option<HelloCaller>,
}
