use flaccy_shared::audio_payload::{self, Location};
use flaccy_shared::track_revision::{self, FileSignature};
use sha2::{Digest, Sha256};
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;
use std::time::UNIX_EPOCH;

const CHUNK: usize = 1 << 20;

/// The size and modification time a scan compares before it reads a file again.
pub fn signature(path: &Path) -> Option<FileSignature> {
    let metadata = std::fs::metadata(path).ok()?;
    let modified = metadata.modified().ok()?.duration_since(UNIX_EPOCH).ok()?;
    Some(FileSignature {
        size: i64::try_from(metadata.len()).ok()?,
        modified_ms: i64::try_from(modified.as_millis()).ok()?,
    })
}

/// Identifies a file's audio: a FLAC's own MD5, or the SHA-256 of the audio
/// ranges for every other format, so a re-tagged copy matches and a re-export
/// does not. `None` when the file cannot be read to the end of its audio.
pub fn fingerprint(path: &Path) -> Option<String> {
    let mut file = File::open(path).ok()?;
    let size = file.metadata().ok()?.len();
    let location = {
        let mut read = |offset: u64, length: usize| read_at(&mut file, offset, length);
        audio_payload::locate(size, &mut read)
    };
    let digest = match &location {
        Location::FlacMd5(_) => None,
        Location::Ranges(ranges) => Some(hash_ranges(&mut file, ranges, size)?),
    };
    track_revision::fingerprint(&location, digest.as_deref())
}

/// The fingerprint a first scan can take without reading the audio: a FLAC's own MD5 sits in its header. `None`
/// for every other format and for a FLAC whose MD5 was never set, which only hashing all of the audio can
/// identify; the revision pass does that in the background so the music is listed first.
pub fn quick_fingerprint(path: &Path) -> Option<String> {
    let mut file = File::open(path).ok()?;
    let size = file.metadata().ok()?.len();
    let location = {
        let mut read = |offset: u64, length: usize| read_at(&mut file, offset, length);
        audio_payload::locate(size, &mut read)
    };
    match location {
        Location::FlacMd5(_) => track_revision::fingerprint(&location, None),
        Location::Ranges(_) => None,
    }
}

fn read_at(file: &mut File, offset: u64, length: usize) -> Vec<u8> {
    let mut buffer = Vec::new();
    if file.seek(SeekFrom::Start(offset)).is_err() {
        return buffer;
    }
    let _ = file.by_ref().take(length as u64).read_to_end(&mut buffer);
    buffer
}

fn hash_ranges(file: &mut File, ranges: &[std::ops::Range<u64>], size: u64) -> Option<String> {
    let mut hasher = Sha256::new();
    let mut buffer = vec![0u8; CHUNK];
    for range in ranges {
        let end = range.end.min(size);
        let mut position = range.start;
        file.seek(SeekFrom::Start(position)).ok()?;
        while position < end {
            let wanted = ((end - position) as usize).min(CHUNK);
            file.read_exact(&mut buffer[..wanted]).ok()?;
            hasher.update(&buffer[..wanted]);
            position += wanted as u64;
        }
    }
    Some(hasher.finalize().iter().map(|byte| format!("{byte:02x}")).collect())
}

/// WAV files written by hand for the tests and the re-export drill, so
/// neither needs an encoder.
pub mod fixtures {

    /// A 16-bit mono 8 kHz WAV whose samples are `samples`, with an optional
    /// `LIST` chunk between the format and data chunks.
    pub fn wav_bytes(samples: &[i16], list_chunk: Option<&[u8]>) -> Vec<u8> {
        let data: Vec<u8> = samples.iter().flat_map(|s| s.to_le_bytes()).collect();
        let mut body = Vec::new();
        body.extend_from_slice(b"WAVE");
        body.extend_from_slice(b"fmt ");
        body.extend_from_slice(&16u32.to_le_bytes());
        body.extend_from_slice(&1u16.to_le_bytes());
        body.extend_from_slice(&1u16.to_le_bytes());
        body.extend_from_slice(&8000u32.to_le_bytes());
        body.extend_from_slice(&16000u32.to_le_bytes());
        body.extend_from_slice(&2u16.to_le_bytes());
        body.extend_from_slice(&16u16.to_le_bytes());
        if let Some(list) = list_chunk {
            body.extend_from_slice(b"LIST");
            body.extend_from_slice(&(list.len() as u32).to_le_bytes());
            body.extend_from_slice(list);
            if list.len() % 2 == 1 {
                body.push(0);
            }
        }
        body.extend_from_slice(b"data");
        body.extend_from_slice(&(data.len() as u32).to_le_bytes());
        body.extend_from_slice(&data);
        let mut file = Vec::new();
        file.extend_from_slice(b"RIFF");
        file.extend_from_slice(&(body.len() as u32).to_le_bytes());
        file.extend_from_slice(&body);
        file
    }

    pub fn tone(length: usize, step: i16) -> Vec<i16> {
        (0..length).map(|i| ((i as i16).wrapping_mul(step)) % 12000).collect()
    }

    /// The payload of a `LIST` chunk carrying the title, artist and album
    /// tags a RIFF WAVE can hold.
    pub fn info_tags(title: &str, artist: &str, album: &str) -> Vec<u8> {
        let mut payload = b"INFO".to_vec();
        for (id, text) in [(b"INAM", title), (b"IART", artist), (b"IPRD", album)] {
            let mut value = text.as_bytes().to_vec();
            value.push(0);
            payload.extend_from_slice(id);
            payload.extend_from_slice(&(value.len() as u32).to_le_bytes());
            payload.extend_from_slice(&value);
            if value.len() % 2 == 1 {
                payload.push(0);
            }
        }
        payload
    }

    /// A uniquely named directory under the system temp dir, removed on drop.
    pub struct TempDir(pub std::path::PathBuf);

    impl TempDir {
        pub fn new(label: &str) -> Self {
            use std::path::PathBuf;
            let path: PathBuf = std::env::temp_dir().join(format!(
                "flaccy-{label}-{}-{}",
                std::process::id(),
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map(|d| d.as_nanos())
                    .unwrap_or(0)
            ));
            std::fs::create_dir_all(&path).expect("temp dir");
            Self(path)
        }

        pub fn path(&self) -> &std::path::Path {
            &self.0
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::fixtures::{tone, wav_bytes, TempDir};
    use super::*;

    #[test]
    fn extra_chunks_around_the_audio_do_not_change_the_fingerprint() {
        let dir = TempDir::new("fingerprint");
        let samples = tone(4000, 7);
        let plain = dir.path().join("plain.wav");
        let tagged = dir.path().join("tagged.wav");
        std::fs::write(&plain, wav_bytes(&samples, None)).unwrap();
        std::fs::write(&tagged, wav_bytes(&samples, Some(b"INFOINAM\x04\x00\x00\x00Song"))).unwrap();
        let first = fingerprint(&plain).expect("plain fingerprint");
        assert!(first.starts_with("sha256:"));
        assert_eq!(Some(first), fingerprint(&tagged));
    }

    #[test]
    fn changing_one_sample_byte_changes_the_fingerprint() {
        let dir = TempDir::new("fingerprint");
        let samples = tone(4000, 7);
        let mut changed = samples.clone();
        changed[1500] = changed[1500].wrapping_add(1);
        let before = dir.path().join("before.wav");
        let after = dir.path().join("after.wav");
        std::fs::write(&before, wav_bytes(&samples, None)).unwrap();
        std::fs::write(&after, wav_bytes(&changed, None)).unwrap();
        assert_ne!(fingerprint(&before), fingerprint(&after));
    }

    #[test]
    fn an_unreadable_path_has_neither_signature_nor_fingerprint() {
        let missing = Path::new("/nonexistent/flaccy/none.wav");
        assert!(signature(missing).is_none());
        assert!(fingerprint(missing).is_none());
    }

    #[test]
    fn the_signature_follows_the_file() {
        let dir = TempDir::new("fingerprint");
        let path = dir.path().join("a.wav");
        std::fs::write(&path, wav_bytes(&tone(100, 3), None)).unwrap();
        let first = signature(&path).expect("signature");
        std::fs::write(&path, wav_bytes(&tone(200, 3), None)).unwrap();
        assert_ne!(Some(first), signature(&path));
    }
}
