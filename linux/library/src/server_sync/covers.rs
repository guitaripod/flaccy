use super::error::Result;
use super::pending::{self, NewMutation, RESEED};
use flaccy_server_core::digest::arg_hash;
use rusqlite::{params, Connection};
use serde_json::Value;
use sha2::{Digest, Sha256};

/// The bytes of a playlist cover this device holds, and the media type to upload them as.
pub(crate) struct LocalBlob {
    pub mime: &'static str,
    pub bytes: Vec<u8>,
}

/// A refused reseed that named covers: what it was and which blobs it needed.
pub(crate) struct RefusedReseed {
    pub id: i64,
    pub args_hash: String,
    pub hashes: Vec<String>,
}

fn reseeds(conn: &Connection, condition: &str) -> Result<Vec<(i64, Value, Vec<String>)>> {
    let mut stmt = conn.prepare(&format!(
        "SELECT mutation_id, args_json, touches_json FROM sync_pending
         WHERE name = '{RESEED}' AND {condition} ORDER BY mutation_id"
    ))?;
    let rows = stmt.query_map([], |row| {
        Ok((
            row.get::<_, i64>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, String>(2)?,
        ))
    })?;
    let mut found = Vec::new();
    for row in rows {
        let (id, args, touches) = row?;
        found.push((
            id,
            serde_json::from_str(&args)?,
            serde_json::from_str(&touches)?,
        ));
    }
    Ok(found)
}

fn cover_hashes(args: &Value) -> Vec<String> {
    let mut hashes: Vec<String> = args["entities"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|entity| entity["kind"] == "playlist")
        .filter_map(|entity| entity["value"]["coverBlob"].as_str().map(str::to_owned))
        .collect();
    hashes.sort();
    hashes.dedup();
    hashes
}

/// The cover blobs named by reseeds no push has carried yet.
pub(crate) fn unsent_cover_hashes(conn: &Connection) -> Result<Vec<String>> {
    let mut hashes: Vec<String> = reseeds(conn, "acked = 0")?
        .iter()
        .flat_map(|(_, args, _)| cover_hashes(args))
        .collect();
    hashes.sort();
    hashes.dedup();
    Ok(hashes)
}

/// Removes a cover from the reseeds that have not been sent, for a blob this device cannot upload: the playlist is reseeded without a picture rather than refused whole.
pub(crate) fn strip_cover(conn: &Connection, hash: &str) -> Result<()> {
    for (id, mut args, _) in reseeds(conn, "acked = 0")? {
        let mut changed = false;
        for entity in args["entities"].as_array_mut().into_iter().flatten() {
            if entity["kind"] == "playlist" && entity["value"]["coverBlob"] == hash {
                entity["value"]["coverBlob"] = Value::Null;
                changed = true;
            }
        }
        if changed {
            conn.execute(
                "UPDATE sync_pending SET args_json = ?1 WHERE mutation_id = ?2",
                params![serde_json::to_string(&args)?, id],
            )?;
        }
    }
    Ok(())
}

/// The reseeds the server refused that named covers.
pub(crate) fn refused_with_covers(conn: &Connection) -> Result<Vec<RefusedReseed>> {
    Ok(reseeds(conn, "failed = 1")?
        .into_iter()
        .filter_map(|(id, args, _)| {
            let hashes = cover_hashes(&args);
            (!hashes.is_empty()).then(|| RefusedReseed {
                id,
                args_hash: arg_hash(RESEED, &args),
                hashes,
            })
        })
        .collect())
}

/// Queues a refused reseed again as a new mutation; the server would only repeat its stored answer to the old id.
pub(crate) fn requeue(conn: &Connection, id: i64) -> Result<()> {
    for (found, args, touches) in reseeds(conn, "1 = 1")? {
        if found == id {
            pending::append(conn, NewMutation::new(RESEED, args, touches))?;
        }
    }
    Ok(())
}

/// The cover stored on this device whose SHA-256 is `hash`.
pub(crate) fn local_blob(conn: &Connection, hash: &str) -> Result<Option<LocalBlob>> {
    let mut stmt =
        conn.prepare("SELECT customCoverData FROM playlists WHERE customCoverData IS NOT NULL")?;
    let rows = stmt.query_map([], |row| row.get::<_, Vec<u8>>(0))?;
    for row in rows {
        let bytes = row?;
        if hex::encode(Sha256::digest(&bytes)) == hash {
            return Ok(Some(LocalBlob {
                mime: sniff(&bytes),
                bytes,
            }));
        }
    }
    Ok(None)
}

fn sniff(bytes: &[u8]) -> &'static str {
    if bytes.starts_with(&[0x89, b'P', b'N', b'G']) {
        "image/png"
    } else if bytes.starts_with(b"RIFF") {
        "image/webp"
    } else {
        "image/jpeg"
    }
}
