//! Writes the server makes on a person's behalf, through the same apply path as a device's mutation.

use flaccy_server_core::apply::{apply_scalar, Caller};
use flaccy_server_core::model::{Scalar, Source};
use flaccy_server_core::mutation::{ListenInput, ScalarOp};
use flaccy_server_core::stamp::Stamp;
use flaccy_server_core::wire::Role;
use rusqlite::{Connection, TransactionBehavior};
use serde_json::Value;
use tokio::sync::broadcast;

use super::apply::Ctx;
use super::listens::record_as;
use super::meta::Counters;
use super::singles::apply_single;
use super::{Poke, Store, SyncError};
use crate::security::UserId;

/// A play the server records itself, with where it came from.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ServerListen {
    /// Where the play came from: `Lastfm` for pulled history, `Opensubsonic` for a third-party client.
    pub source: Source,
    /// The play.
    pub input: ListenInput,
}

fn server_caller(user: &UserId) -> Caller {
    Caller {
        user: user.to_string(),
        role: Role::Member,
        device: String::new(),
    }
}

fn announce(pokes: &broadcast::Sender<Poke>, counters: &mut Counters) {
    let (made, _) = counters.take_effects();
    for poke in made {
        let _ = pokes.send(poke);
    }
}

fn listens_of(listens: &[ServerListen], source: Source) -> Vec<ListenInput> {
    listens.iter().filter(|listen| listen.source == source).map(|listen| listen.input.clone()).collect()
}

/// How many of `inputs` the listens table does not hold yet.
fn unseen(connection: &Connection, inputs: &[ListenInput]) -> Result<usize, SyncError> {
    let mut statement = connection.prepare_cached("SELECT 1 FROM listens WHERE event_id = ?1")?;
    let mut missing = 0;
    for input in inputs {
        if !statement.exists([&input.event_id])? {
            missing += 1;
        }
    }
    Ok(missing)
}

fn record_all(connection: &mut Connection, caller: &Caller, listens: &[ServerListen], now_ms: i64, pokes: &broadcast::Sender<Poke>) -> Result<usize, SyncError> {
    let mut counters = Counters::load(connection)?;
    let stamp = counters.clock.next(now_ms);
    let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let mut ctx = Ctx { caller, stamp, counters: &mut counters };
    let mut added = 0;
    for source in [Source::Flaccy, Source::Lastfm, Source::Opensubsonic, Source::Migrated] {
        let inputs = listens_of(listens, source);
        if inputs.is_empty() {
            continue;
        }
        added += unseen(&transaction, &inputs)?;
        record_as(&transaction, &inputs, source, &mut ctx)?;
    }
    counters.save(&transaction)?;
    transaction.commit()?;
    announce(pokes, &mut counters);
    Ok(added)
}

fn set_scalar(connection: &mut Connection, caller: &Caller, op: &ScalarOp, now_ms: i64, pokes: &broadcast::Sender<Poke>) -> Result<(), SyncError> {
    let mut counters = Counters::load(connection)?;
    let stamp: Stamp = counters.clock.next(now_ms);
    let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    apply_single::<Scalar>(&transaction, &mut counters, &caller.user, op.key(), |slot| apply_scalar(slot, op, caller, stamp))?;
    counters.save(&transaction)?;
    transaction.commit()?;
    announce(pokes, &mut counters);
    Ok(())
}

impl Store {
    /// Records plays on behalf of `user` as the server, not as a device: the same insert, ledger and change feed as
    /// `listen.record`, with the source each play names and no device. Plays already stored are skipped; answers how many
    /// were new.
    pub async fn record_listens_as_server(&self, user: &UserId, listens: Vec<ServerListen>) -> Result<usize, SyncError> {
        let caller = server_caller(user);
        let now_ms = self.now_ms();
        let pokes = self.inner.pokes.clone();
        self.write(move |connection| record_all(connection, &caller, &listens, now_ms, &pokes)).await
    }

    /// Sets a scalar of `user` as the server does for `flaccy-server lastfm account`.
    pub async fn set_scalar_as_server(&self, user: &UserId, key: &str, value: Value) -> Result<(), SyncError> {
        let caller = server_caller(user);
        let op = ScalarOp::Set { key: key.to_owned(), value };
        let now_ms = self.now_ms();
        let pokes = self.inner.pokes.clone();
        self.write(move |connection| set_scalar(connection, &caller, &op, now_ms, &pokes)).await
    }
}
