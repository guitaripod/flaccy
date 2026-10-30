//! Compares `keys::normalize` with the Swift original, `LibraryHygiene.normalize`, over every Unicode scalar.
//!
//! On a Mac, `swiftc -O scripts/key-fold-dump.swift -o key-fold-dump && ./key-fold-dump > dump.txt` writes a line
//! `<scalar hex> <result hex,…>` for each scalar the Swift function keeps. `cargo run --release --example
//! key_fold_diff -- dump.txt` then lists, by Unicode block, where Rust answers differently, which is where an
//! artist or title would get another song key on iPhone than on Linux.

use std::collections::BTreeMap;

use flaccy_library::keys::normalize;

const LAST_BASIC_PLANE_SCALAR: u32 = 0xFFFF;
const SAMPLE_SIZE: usize = 8;

fn read_dump(path: &str) -> BTreeMap<u32, String> {
    let text = std::fs::read_to_string(path).unwrap_or_else(|error| panic!("cannot read {path}: {error}"));
    text.lines()
        .filter_map(|line| {
            let (scalar, result) = line.split_once(' ')?;
            let text: Option<String> = result.split(',').map(|hex| u32::from_str_radix(hex, 16).ok().and_then(char::from_u32)).collect();
            Some((u32::from_str_radix(scalar, 16).ok()?, text?))
        })
        .collect()
}

fn describe(swift: &str, rust: &str) -> &'static str {
    match (swift.is_empty(), rust.is_empty()) {
        (false, true) => "rust drops",
        (true, false) => "swift drops",
        _ => "both keep, differ",
    }
}

fn main() {
    let path = std::env::args().nth(1).expect("usage: key_fold_diff <dump.txt>");
    let swift = read_dump(&path);
    let mut blocks: BTreeMap<(u32, &str), (usize, String)> = BTreeMap::new();
    for value in 0..=LAST_BASIC_PLANE_SCALAR {
        let Some(scalar) = char::from_u32(value) else { continue };
        let expected = swift.get(&value).map(String::as_str).unwrap_or("");
        let actual = normalize(&scalar.to_string());
        if expected == actual {
            continue;
        }
        let (count, sample) = blocks.entry((value >> 8, describe(expected, &actual))).or_default();
        *count += 1;
        if sample.chars().count() < SAMPLE_SIZE {
            sample.push(scalar);
        }
    }
    let total: usize = blocks.values().map(|(count, _)| count).sum();
    println!("{total} scalars in the Basic Multilingual Plane are normalized differently");
    for ((block, kind), (count, sample)) in blocks {
        println!("U+{block:02X}xx {kind:18} {count:4} {sample}");
    }
}
