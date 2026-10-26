#![allow(dead_code)]

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

static NEXT: AtomicU64 = AtomicU64::new(0);

pub struct TempDir(PathBuf);

impl TempDir {
    pub fn new(label: &str) -> Self {
        let path = std::env::temp_dir().join(format!(
            "flaccy-{label}-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir_all(&path).unwrap();
        Self(path)
    }

    pub fn path(&self) -> &Path {
        &self.0
    }

    pub fn file(&self, name: &str) -> PathBuf {
        self.0.join(name)
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

use flaccy_server::security::{DeviceId, Principal, Role, UserId};
use flaccy_server_core::song::song_key;
use flaccy_server_core::stamp::Stamp;
use flaccy_server_core::wire::{Mutation, PushRequest};
use serde_json::{json, Value};

pub const BASE_TIME_MS: i64 = 1_790_000_000_000;

pub fn member(user: &str, device: &str) -> Principal {
    Principal {
        user: UserId(user.to_owned()),
        role: Role::Member,
        device: Some(DeviceId(device.to_owned())),
    }
}

pub fn song(index: usize) -> Value {
    json!({
        "songKey": song_key(&format!("artist{index}"), &format!("title{index}")),
        "title": format!("Title {index}"),
        "artist": format!("Artist {index}"),
        "album": "Album",
        "durationMs": 180000,
    })
}

pub fn mutation(id: i64, name: &str, args: Value) -> Mutation {
    Mutation {
        id,
        name: name.to_owned(),
        stamp: Stamp((BASE_TIME_MS << 16) + id),
        args,
    }
}

pub fn request(device: &str, instance: &str, mutations: Vec<Mutation>) -> PushRequest {
    PushRequest {
        device: device.to_owned(),
        instance: instance.to_owned(),
        mutations,
    }
}

pub mod child;
pub mod http;
