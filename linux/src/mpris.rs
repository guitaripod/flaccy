use crate::app::AppCore;
use crate::db::Db;
use crate::events::AppEvent;
use crate::library::Track;
use gtk::glib;
use mpris_server::zbus::zvariant::ObjectPath;
use mpris_server::{LoopStatus, Metadata, PlaybackStatus, Player, Time};
use std::cell::Cell;
use std::path::PathBuf;
use std::rc::Rc;

pub fn start(core: &Rc<AppCore>) {
    let core = Rc::clone(core);
    glib::spawn_future_local(async move {
        let bus_suffix = if crate::config::demo_mode() {
            "cc.midgarcorp.Flaccy.Demo"
        } else {
            "cc.midgarcorp.Flaccy"
        };
        let player = match Player::builder(bus_suffix)
            .identity("Flaccy")
            .desktop_entry("cc.midgarcorp.Flaccy")
            .can_play(true)
            .can_pause(true)
            .can_go_next(true)
            .can_go_previous(true)
            .can_seek(true)
            .can_control(true)
            .build()
            .await
        {
            Ok(player) => Rc::new(player),
            Err(err) => {
                crate::logger::warn("mpris", &format!("mpris unavailable: {err}"));
                return;
            }
        };

        {
            let core = Rc::clone(&core);
            player.connect_play_pause(move |_| core.toggle_play_pause());
        }
        {
            let core = Rc::clone(&core);
            player.connect_play(move |_| {
                if !core.player.is_playing() {
                    core.toggle_play_pause();
                }
            });
        }
        {
            let core = Rc::clone(&core);
            player.connect_pause(move |_| {
                if core.player.is_playing() {
                    core.toggle_play_pause();
                }
            });
        }
        {
            let core = Rc::clone(&core);
            player.connect_next(move |_| core.next());
        }
        {
            let core = Rc::clone(&core);
            player.connect_previous(move |_| core.previous());
        }
        {
            let core = Rc::clone(&core);
            player.connect_seek(move |_, offset| {
                core.skip_by(offset.as_micros() as f64 / 1_000_000.0);
            });
        }
        {
            let core = Rc::clone(&core);
            player.connect_set_position(move |_, track_id, position| {
                let Some(track) = core.player.current_track() else {
                    return;
                };
                let seconds = position.as_micros() as f64 / 1_000_000.0;
                if track_id.as_str() == track_path(&track) && accepts_position(seconds, track.duration)
                {
                    core.player.seek(seconds);
                }
            });
        }
        {
            let core = Rc::clone(&core);
            player.connect_set_volume(move |_, volume| {
                core.set_volume(volume.clamp(0.0, 1.0));
            });
        }
        {
            let core = Rc::clone(&core);
            player.connect_set_shuffle(move |_, wanted| {
                if core.player.shuffle_enabled() != wanted {
                    core.player.toggle_shuffle();
                }
            });
        }
        {
            let core = Rc::clone(&core);
            player.connect_set_loop_status(move |_, wanted| {
                let target = match wanted {
                    LoopStatus::None => crate::player::RepeatMode::Off,
                    LoopStatus::Playlist => crate::player::RepeatMode::All,
                    LoopStatus::Track => crate::player::RepeatMode::One,
                };
                for _ in 0..3 {
                    if core.player.repeat_mode() == target {
                        break;
                    }
                    core.player.cycle_repeat();
                }
            });
        }

        glib::spawn_future_local(player.run());
        *core.mpris.borrow_mut() = Some(Rc::clone(&player));

        let hub = Rc::clone(&core.hub);
        let weak_core = Rc::downgrade(&core);
        let metadata_generation = Rc::new(Cell::new(0_u64));
        hub.subscribe(move |event| {
            let Some(core) = weak_core.upgrade() else {
                return false;
            };
            let Some(player) = core.mpris.borrow().clone() else {
                return true;
            };
            match event {
                AppEvent::TrackChanged(track) => {
                    publish_metadata(&core, &player, &metadata_generation, track.clone());
                }
                AppEvent::AlbumArtworkChanged { title, artist } => {
                    let playing_this = core
                        .player
                        .current_track()
                        .filter(|track| &track.album == title && &track.artist == artist);
                    if let Some(track) = playing_this {
                        publish_metadata(&core, &player, &metadata_generation, Some(track));
                    }
                }
                AppEvent::PlayingChanged(playing) => {
                    let status = if *playing {
                        PlaybackStatus::Playing
                    } else {
                        PlaybackStatus::Paused
                    };
                    glib::spawn_future_local(async move {
                        let _ = player.set_playback_status(status).await;
                    });
                }
                AppEvent::Tick { position, .. } => {
                    player.set_position(Time::from_millis((*position * 1000.0) as i64));
                }
                AppEvent::Seeked(position) => {
                    let time = Time::from_millis((*position * 1000.0) as i64);
                    player.set_position(time);
                    glib::spawn_future_local(async move {
                        let _ = player.seeked(time).await;
                    });
                }
                AppEvent::ShuffleChanged(enabled) => {
                    let enabled = *enabled;
                    glib::spawn_future_local(async move {
                        let _ = player.set_shuffle(enabled).await;
                    });
                }
                AppEvent::RepeatChanged(mode) => {
                    let status = match mode {
                        crate::player::RepeatMode::Off => LoopStatus::None,
                        crate::player::RepeatMode::All => LoopStatus::Playlist,
                        crate::player::RepeatMode::One => LoopStatus::Track,
                    };
                    glib::spawn_future_local(async move {
                        let _ = player.set_loop_status(status).await;
                    });
                }
                AppEvent::VolumeChanged(volume) => {
                    let volume = *volume;
                    glib::spawn_future_local(async move {
                        let _ = player.set_volume(volume).await;
                    });
                }
                _ => {}
            }
            true
        });
        crate::logger::info("mpris", "MPRIS2 interface registered");
    });
}

/// Publishes the metadata for `track` once its cover is exported.
///
/// The cover read, hash and write happen on a worker thread, so a track change
/// never waits on the disk. Each call takes a new generation number and the
/// result is applied only if it is still the newest, which keeps a fast skip
/// (or a cover change landing mid-export) from putting a stale track's art on
/// the shell after the current track's metadata.
fn publish_metadata(
    core: &Rc<AppCore>,
    player: &Rc<Player>,
    generation: &Rc<Cell<u64>>,
    track: Option<Track>,
) {
    let ticket = generation.get() + 1;
    generation.set(ticket);
    let Some(track) = track else {
        let player = Rc::clone(player);
        glib::spawn_future_local(async move {
            let _ = player.set_metadata(Metadata::new()).await;
        });
        return;
    };
    let db_path = core.db_path.clone();
    let (album, artist) = (track.album.clone(), track.artist.clone());
    let (tx, rx) = async_channel::bounded::<Option<PathBuf>>(1);
    std::thread::spawn(move || {
        let _ = tx.send_blocking(export_artwork(&db_path, &album, &artist));
    });
    let player = Rc::clone(player);
    let generation = Rc::clone(generation);
    glib::spawn_future_local(async move {
        let art = rx.recv().await.ok().flatten();
        if generation.get() != ticket {
            return;
        }
        let _ = player.set_metadata(metadata_for(&track, art)).await;
    });
}

fn metadata_for(track: &Track, art: Option<PathBuf>) -> Metadata {
    let mut builder = Metadata::builder()
        .title(track.title.clone())
        .artist([track.artist.clone()])
        .album(track.album.clone())
        .length(Time::from_millis((track.duration * 1000.0) as i64));
    if let Ok(path) = ObjectPath::try_from(track_path(track)) {
        builder = builder.trackid(path);
    }
    if let Some(art) = art {
        if let Ok(uri) = glib::filename_to_uri(&art, None::<&str>) {
            builder = builder.art_url(uri.to_string());
        }
    }
    builder.build()
}

fn track_path(track: &Track) -> String {
    format!("/cc/midgarcorp/Flaccy/Track/{}", track.id)
}

/// MPRIS says a `SetPosition` past the end of the track, or before its start,
/// is to be ignored. A request for a track that is no longer playing is dropped
/// by the caller: a desktop widget dragging its slider across a track change
/// would otherwise seek the next song.
fn accepts_position(seconds: f64, duration: f64) -> bool {
    seconds >= 0.0 && (duration <= 0.0 || seconds <= duration)
}

/// Writes the album's current cover where a desktop shell can read it. The
/// file name carries a hash of the picture itself, so a cover the person just
/// chose gets a new URL and the shell cannot keep showing the old one; files
/// left by earlier covers of the same album are removed.
fn export_artwork(db_path: &std::path::Path, album_title: &str, artist: &str) -> Option<PathBuf> {
    let cache_dir = dirs::cache_dir()?.join("flaccy").join("mpris");
    std::fs::create_dir_all(&cache_dir).ok()?;
    let data = Db::open(db_path)
        .ok()?
        .fetch_album_artwork(album_title, artist)?;
    let album = crate::palette::fnv1a_64(&format!("{album_title}|{artist}"));
    let prefix = format!("{album:016x}-");
    let path = cache_dir.join(format!("{prefix}{:016x}.img", content_hash(&data)));
    if path.exists() {
        return Some(path);
    }
    remove_stale_exports(&cache_dir, &prefix);
    write_atomically(&cache_dir, &path, &data)?;
    Some(path)
}

/// Writes through a dot-prefixed temporary name and renames it into place, so
/// two exports of the same album running at once never leave a half-written
/// file at the URL the shell is about to read, and the stale-export sweep, which
/// matches only the album prefix, never removes a file still being written.
fn write_atomically(directory: &std::path::Path, path: &std::path::Path, data: &[u8]) -> Option<()> {
    static SEQUENCE: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let unique = SEQUENCE.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let staging = directory.join(format!(".export-{}-{unique}.tmp", std::process::id()));
    std::fs::write(&staging, data).ok()?;
    if std::fs::rename(&staging, path).is_err() {
        let _ = std::fs::remove_file(&staging);
        return None;
    }
    Some(())
}

fn content_hash(data: &[u8]) -> u64 {
    use std::hash::{Hash, Hasher};
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    data.hash(&mut hasher);
    hasher.finish()
}

fn remove_stale_exports(directory: &std::path::Path, prefix: &str) {
    let Ok(entries) = std::fs::read_dir(directory) else {
        return;
    };
    for entry in entries.flatten() {
        if entry.file_name().to_string_lossy().starts_with(prefix) {
            let _ = std::fs::remove_file(entry.path());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{accepts_position, content_hash, remove_stale_exports, write_atomically};

    #[test]
    fn a_new_cover_gets_a_new_file_name_and_the_old_export_is_removed() {
        let dir = std::env::temp_dir().join(format!("flaccy-mpris-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("dir");
        assert_ne!(content_hash(&[1, 2, 3]), content_hash(&[1, 2, 4]));
        assert_eq!(content_hash(&[1, 2, 3]), content_hash(&[1, 2, 3]));
        std::fs::write(dir.join("00aa-0001.img"), b"old").expect("old export");
        std::fs::write(dir.join("00bb-0001.img"), b"other album").expect("other export");
        remove_stale_exports(&dir, "00aa-");
        assert!(!dir.join("00aa-0001.img").exists());
        assert!(dir.join("00bb-0001.img").exists(), "other albums keep theirs");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn an_export_lands_whole_and_leaves_no_staging_file() {
        let dir = std::env::temp_dir().join(format!("flaccy-mpris-atomic-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("dir");
        let target = dir.join("00aa-0001.img");
        write_atomically(&dir, &target, b"cover").expect("written");
        write_atomically(&dir, &target, b"cover").expect("rewritten");
        assert_eq!(std::fs::read(&target).expect("read"), b"cover");
        assert_eq!(std::fs::read_dir(&dir).expect("list").count(), 1);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn set_position_stays_inside_the_track() {
        assert!(accepts_position(0.0, 200.0));
        assert!(accepts_position(200.0, 200.0));
        assert!(!accepts_position(200.5, 200.0));
        assert!(!accepts_position(-1.0, 200.0));
        assert!(accepts_position(999.0, 0.0));
    }
}
