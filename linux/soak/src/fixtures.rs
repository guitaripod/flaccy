use flaccy_library::db::NewTrack;
use flaccy_library::server_sync::song_key_of;
use std::collections::HashMap;
use std::path::Path;
use std::process::{Child, Command, Stdio};

const SONG_COUNT: usize = 200;
const ARTISTS: usize = 10;
const ALBUMS_PER_ARTIST: usize = 4;
const PARALLEL_ENCODERS: usize = 8;

/// How many songs carry a lyrics row on every client, so synced lyric offsets have somewhere to land.
pub const LYRIC_SONGS: usize = 40;

/// One song of the generated library.
#[derive(Clone, Debug)]
pub struct Song {
    /// Path under the music folder.
    pub rel_path: String,
    /// The tag title.
    pub title: String,
    /// The tag artist.
    pub artist: String,
    /// The tag album.
    pub album: String,
    /// Track number inside the album.
    pub track: i32,
    /// The shared song key.
    pub key: String,
}

/// The generated library, shared by the server's scan and every client's database.
pub struct Catalog {
    /// Every song in generation order.
    pub songs: Vec<Song>,
    by_path: HashMap<String, usize>,
}

impl Catalog {
    /// Writes 200 one-second FLAC files under `music` with ffmpeg and describes them.
    pub fn generate(music: &Path) -> Result<Catalog, String> {
        let songs = describe_songs();
        let mut running: Vec<Child> = Vec::new();
        for (index, song) in songs.iter().enumerate() {
            let path = music.join(&song.rel_path);
            if let Some(parent) = path.parent() {
                std::fs::create_dir_all(parent).map_err(|error| format!("cannot create {}: {error}", parent.display()))?;
            }
            running.push(encode(&path, song, index)?);
            if running.len() >= PARALLEL_ENCODERS {
                finish_all(&mut running)?;
            }
        }
        finish_all(&mut running)?;
        let by_path = songs.iter().enumerate().map(|(index, song)| (song.rel_path.clone(), index)).collect();
        Ok(Catalog { songs, by_path })
    }

    /// The song key of a library path.
    pub fn key_of_path(&self, rel_path: &str) -> Option<&str> {
        self.by_path.get(rel_path).map(|index| self.songs[*index].key.as_str())
    }

    /// The row a client scan would insert for `song`.
    pub fn new_track(&self, song: &Song) -> NewTrack {
        NewTrack {
            rel_path: song.rel_path.clone(),
            title: song.title.clone(),
            artist: song.artist.clone(),
            album: song.album.clone(),
            album_artist: None,
            track_number: song.track,
            duration: 1.0,
            codec: Some("FLAC".into()),
            bit_depth: None,
            sample_rate: None,
            channels: None,
            artwork: None,
            signature: None,
            fingerprint: None,
        }
    }
}

fn describe_songs() -> Vec<Song> {
    let per_artist = SONG_COUNT / ARTISTS;
    let per_album = per_artist / ALBUMS_PER_ARTIST;
    (0..SONG_COUNT)
        .map(|index| {
            let artist_index = index / per_artist;
            let album_index = (index % per_artist) / per_album;
            let track = (index % per_album) as i32 + 1;
            let title = format!("Soak Song {index:03}");
            let artist = format!("Soak Artist {artist_index}");
            let album = format!("Soak Album {artist_index}-{album_index}");
            Song {
                rel_path: format!("{artist}/{album}/{track:02} {title}.flac"),
                key: song_key_of(&title, &artist),
                title,
                artist,
                album,
                track,
            }
        })
        .collect()
}

fn encode(path: &Path, song: &Song, index: usize) -> Result<Child, String> {
    Command::new("ffmpeg")
        .args(["-loglevel", "error", "-y", "-f", "lavfi", "-i"])
        .arg(format!("sine=frequency={}:duration=1:sample_rate=8000", 200 + index * 7))
        .args(["-ac", "1", "-metadata"])
        .arg(format!("title={}", song.title))
        .arg("-metadata")
        .arg(format!("artist={}", song.artist))
        .arg("-metadata")
        .arg(format!("album={}", song.album))
        .arg("-metadata")
        .arg(format!("track={}", song.track))
        .arg(path)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|error| format!("cannot run ffmpeg to generate the fixture library: {error}. Install ffmpeg."))
}

fn finish_all(running: &mut Vec<Child>) -> Result<(), String> {
    for mut child in running.drain(..) {
        let status = child.wait().map_err(|error| format!("ffmpeg did not finish: {error}"))?;
        if !status.success() {
            return Err(format!("ffmpeg failed with {status} while generating the fixture library"));
        }
    }
    Ok(())
}
