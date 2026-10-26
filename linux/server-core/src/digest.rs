//! Canonical JSON and the hashes built on it.

use crate::model::Entity;
use serde_json::Value;
use sha2::{Digest, Sha256};

fn write_canonical(value: &Value, out: &mut String) {
    match value {
        Value::Object(map) => {
            let mut keys: Vec<&String> = map.keys().collect();
            keys.sort();
            out.push('{');
            for (index, key) in keys.into_iter().enumerate() {
                if index > 0 {
                    out.push(',');
                }
                out.push_str(&Value::String(key.clone()).to_string());
                out.push(':');
                write_canonical(&map[key], out);
            }
            out.push('}');
        }
        Value::Array(items) => {
            out.push('[');
            for (index, item) in items.iter().enumerate() {
                if index > 0 {
                    out.push(',');
                }
                write_canonical(item, out);
            }
            out.push(']');
        }
        scalar => out.push_str(&scalar.to_string()),
    }
}

/// The JSON text of a value with object keys sorted and no whitespace.
pub fn canonical_json(value: &Value) -> String {
    let mut out = String::new();
    write_canonical(value, &mut out);
    out
}

fn sha256_hex(text: &str) -> String {
    hex::encode(Sha256::digest(text.as_bytes()))
}

/// The retry check hash of a mutation: SHA-256 over its name and canonical args, hex.
pub fn arg_hash(name: &str, args: &Value) -> String {
    sha256_hex(&format!("{name}\n{}", canonical_json(args)))
}

/// SHA-256 over the canonical JSON of the entities sorted by kind and id, hex: equal states give equal digests.
pub fn state_digest(entities: &[Entity]) -> String {
    let mut sorted: Vec<&Entity> = entities.iter().collect();
    sorted.sort_by(|a, b| a.kind.cmp(&b.kind).then_with(|| a.id.cmp(&b.id)));
    let rows: Vec<Value> = sorted
        .into_iter()
        .map(|entity| {
            let kind = serde_json::to_value(entity.kind).unwrap_or(Value::Null);
            Value::Array(vec![
                kind,
                Value::String(entity.id.clone()),
                entity.value.clone(),
            ])
        })
        .collect();
    sha256_hex(&canonical_json(&Value::Array(rows)))
}
