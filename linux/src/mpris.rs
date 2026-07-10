use crate::app::AppCore;
use crate::events::AppEvent;
use crate::library::Track;
use gtk::glib;
use mpris_server::zbus::zvariant::ObjectPath;
use mpris_server::{Metadata, PlaybackStatus, Player, Time};
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
                let position = core.player.position().unwrap_or(0.0);
                core.player.seek(position + offset.as_secs() as f64);
            });
        }
        {
            let core = Rc::clone(&core);
            player.connect_set_position(move |_, _, position| {
                core.player.seek(position.as_millis() as f64 / 1000.0);
            });
        }
        {
            let core = Rc::clone(&core);
            player.connect_set_volume(move |_, volume| {
                core.set_volume(volume.clamp(0.0, 1.0));
            });
        }

        glib::spawn_future_local(player.run());
        *core.mpris.borrow_mut() = Some(Rc::clone(&player));

        let hub = Rc::clone(&core.hub);
        let weak_core = Rc::downgrade(&core);
        hub.subscribe(move |event| {
            let Some(core) = weak_core.upgrade() else { return false };
            let Some(player) = core.mpris.borrow().clone() else { return true };
            match event {
                AppEvent::TrackChanged(track) => {
                    let metadata = metadata_for(&core, track.as_ref());
                    glib::spawn_future_local(async move {
                        let _ = player.set_metadata(metadata).await;
                    });
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

fn metadata_for(core: &Rc<AppCore>, track: Option<&Track>) -> Metadata {
    let Some(track) = track else {
        return Metadata::new();
    };
    let mut builder = Metadata::builder()
        .title(track.title.clone())
        .artist([track.artist.clone()])
        .album(track.album.clone())
        .length(Time::from_millis((track.duration * 1000.0) as i64));
    if let Ok(path) = ObjectPath::try_from(format!("/cc/midgarcorp/Flaccy/Track/{}", track.id)) {
        builder = builder.trackid(path);
    }
    if let Some(art) = export_artwork(core, track) {
        if let Ok(uri) = glib::filename_to_uri(&art, None::<&str>) {
            builder = builder.art_url(uri.to_string());
        }
    }
    builder.build()
}

fn export_artwork(core: &Rc<AppCore>, track: &Track) -> Option<PathBuf> {
    let cache_dir = dirs::cache_dir()?.join("flaccy").join("mpris");
    std::fs::create_dir_all(&cache_dir).ok()?;
    let key = crate::palette::fnv1a_64(&format!("{}|{}", track.album, track.artist));
    let path = cache_dir.join(format!("{key:016x}.img"));
    if path.exists() {
        return Some(path);
    }
    let data = core.db.fetch_album_artwork(&track.album, &track.artist)?;
    std::fs::write(&path, &data).ok()?;
    Some(path)
}
