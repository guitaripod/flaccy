//! Mirrors `Core/FlaccyCore/Sources/FlaccyCore/Library/AudioPayload.swift`.
//!
//! Which bytes of a file identify its audio, so a re-tagged copy of a song is
//! recognised as the same audio and a re-encoded one is not. The container is
//! read by its magic bytes, never by its extension: a FLAC carries its own MD5
//! of the decoded samples, and every other format is hashed over the byte
//! ranges that hold the audio payload, skipping tags on either end.

use std::ops::Range;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Location {
    FlacMd5(String),
    Ranges(Vec<Range<u64>>),
}

/// Decides where the audio of a file lives. `read(offset, length)` returns up
/// to `length` bytes starting at `offset`, fewer only at the end of the file.
pub fn locate(file_size: u64, read: &mut dyn FnMut(u64, usize) -> Vec<u8>) -> Location {
    if file_size == 0 {
        return Location::Ranges(Vec::new());
    }
    let mut probe = Probe {
        size: file_size,
        read,
    };
    let start = skip_id3v2(&mut probe);
    if start >= file_size {
        return whole_file(file_size);
    }
    if probe.starts_with(start, b"fLaC") {
        flac(&mut probe, start)
    } else if probe.starts_with(start, b"RIFF") && probe.starts_with(start + 8, b"WAVE") {
        riff_wave(&mut probe, start)
    } else if probe.starts_with(start, b"FORM")
        && (probe.starts_with(start + 8, b"AIFF") || probe.starts_with(start + 8, b"AIFC"))
    {
        aiff(&mut probe, start)
    } else if probe.starts_with(start + 4, b"ftyp") {
        mp4(&mut probe, start)
    } else {
        unknown(&mut probe, start)
    }
}

struct Probe<'a> {
    size: u64,
    read: &'a mut dyn FnMut(u64, usize) -> Vec<u8>,
}

impl Probe<'_> {
    /// Bytes from `offset`, clamped to the end of the file. Empty past it.
    fn bytes(&mut self, offset: u64, length: u64) -> Vec<u8> {
        if offset >= self.size || length == 0 {
            return Vec::new();
        }
        let available = (self.size - offset).min(length) as usize;
        let mut data = (self.read)(offset, available);
        data.truncate(available);
        data
    }

    /// The exact `length` bytes at `offset`, or `None` when the file ends first.
    fn exact(&mut self, offset: u64, length: u64) -> Option<Vec<u8>> {
        let data = self.bytes(offset, length);
        (data.len() as u64 == length).then_some(data)
    }

    fn starts_with(&mut self, offset: u64, magic: &[u8]) -> bool {
        self.bytes(offset, magic.len() as u64) == magic
    }

    fn u32_le(&mut self, offset: u64) -> Option<u64> {
        self.exact(offset, 4)
            .map(|b| u32::from_le_bytes([b[0], b[1], b[2], b[3]]) as u64)
    }

    fn u64_be(&mut self, offset: u64) -> Option<u64> {
        self.exact(offset, 8)
            .map(|b| u64::from_be_bytes([b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7]]))
    }
}

fn whole_file(file_size: u64) -> Location {
    Location::Ranges(vec![0..file_size])
}

/// Skips every leading ID3v2 tag. A tag header cut short by the end of the
/// file makes the whole file the audio, the only safe reading of it.
fn skip_id3v2(probe: &mut Probe) -> u64 {
    let mut start = 0;
    while probe.starts_with(start, b"ID3") {
        let Some(header) = probe.exact(start, 10) else {
            return probe.size;
        };
        let size = syncsafe(&header[6..10]);
        let footer = if header[5] & 0x10 != 0 { 10 } else { 0 };
        start = start.saturating_add(10 + size + footer);
        if start >= probe.size {
            break;
        }
    }
    start
}

/// A 28-bit size spread over four bytes, seven bits each, most significant first.
fn syncsafe(bytes: &[u8]) -> u64 {
    bytes
        .iter()
        .fold(0u64, |value, byte| (value << 7) | u64::from(byte & 0x7F))
}

/// Walks the metadata blocks, taking the MD5 from STREAMINFO. The audio begins
/// after the last block; a block running past the end of the file makes the
/// whole file the audio.
fn flac(probe: &mut Probe, start: u64) -> Location {
    let mut offset = start + 4;
    let mut md5: Option<Vec<u8>> = None;
    loop {
        let Some(header) = probe.exact(offset, 4) else {
            return whole_file(probe.size);
        };
        let last = header[0] & 0x80 != 0;
        let kind = header[0] & 0x7F;
        let length = u64::from(header[1]) << 16 | u64::from(header[2]) << 8 | u64::from(header[3]);
        let data = offset + 4;
        if data + length > probe.size {
            return whole_file(probe.size);
        }
        if kind == 0 && length >= 34 && md5.is_none() {
            md5 = probe.exact(data + 18, 16);
        }
        offset = data + length;
        if last {
            break;
        }
    }
    match md5 {
        Some(digest) if digest.iter().any(|byte| *byte != 0) => {
            Location::FlacMd5(digest.iter().map(|byte| format!("{byte:02x}")).collect())
        }
        _ => Location::Ranges(vec![offset..probe.size]),
    }
}

/// The `data` chunk of a WAVE file, payload only. A chunk header past the end
/// of the file, or no `data` chunk at all, makes the whole file the audio.
fn riff_wave(probe: &mut Probe, start: u64) -> Location {
    let mut offset = start + 12;
    loop {
        let Some(header) = probe.exact(offset, 8) else {
            return whole_file(probe.size);
        };
        let size = u64::from(u32::from_le_bytes([
            header[4], header[5], header[6], header[7],
        ]));
        let payload = offset + 8;
        if &header[0..4] == b"data" {
            return Location::Ranges(vec![payload..payload.saturating_add(size).min(probe.size)]);
        }
        offset = payload.saturating_add(size + (size & 1));
    }
}

/// The `SSND` chunk of an AIFF or AIFC file, payload only, offset and block
/// size fields included. Without it the whole file is the audio.
fn aiff(probe: &mut Probe, start: u64) -> Location {
    let mut offset = start + 12;
    loop {
        let Some(header) = probe.exact(offset, 8) else {
            return whole_file(probe.size);
        };
        let size = u64::from(u32::from_be_bytes([
            header[4], header[5], header[6], header[7],
        ]));
        let payload = offset + 8;
        if &header[0..4] == b"SSND" {
            return Location::Ranges(vec![payload..payload.saturating_add(size).min(probe.size)]);
        }
        offset = payload.saturating_add(size + (size & 1));
    }
}

/// Every top-level `mdat` box, payload only, in file order. A box size smaller
/// than its own header, or no `mdat` at all, makes the whole file the audio.
fn mp4(probe: &mut Probe, start: u64) -> Location {
    let mut ranges = Vec::new();
    let mut offset = start;
    while offset < probe.size {
        let Some(header) = probe.exact(offset, 8) else {
            break;
        };
        let size32 = u64::from(u32::from_be_bytes([
            header[0], header[1], header[2], header[3],
        ]));
        let (header_length, box_size) = match size32 {
            1 => match probe.u64_be(offset + 8) {
                Some(large) => (16, large),
                None => break,
            },
            0 => (8, probe.size - offset),
            size => (8, size),
        };
        if box_size < header_length {
            return whole_file(probe.size);
        }
        let box_end = offset.saturating_add(box_size);
        if &header[4..8] == b"mdat" {
            ranges.push((offset + header_length)..box_end.min(probe.size));
        }
        if box_end >= probe.size {
            break;
        }
        offset = box_end;
    }
    if ranges.is_empty() {
        whole_file(probe.size)
    } else {
        Location::Ranges(ranges)
    }
}

/// Everything after the ID3v2 tag is audio, minus an ID3v1 `TAG` trailer and
/// an APEv2 footer (with its items, when the footer says a header is present).
fn unknown(probe: &mut Probe, start: u64) -> Location {
    let mut end = probe.size;
    if end - start >= 128 && probe.starts_with(end - 128, b"TAG") {
        end -= 128;
    }
    if end - start >= 32 && probe.starts_with(end - 32, b"APETAGEX") {
        let size = probe.u32_le(end - 32 + 12).unwrap_or(0);
        let flags = probe.u32_le(end - 32 + 20).unwrap_or(0);
        let header = if flags & 0x8000_0000 != 0 { 32 } else { 0 };
        end = end.saturating_sub(size + header);
    }
    if end <= start {
        return whole_file(probe.size);
    }
    Location::Ranges(vec![start..end])
}

#[cfg(test)]
mod tests {
    use super::*;

    fn reader(bytes: &[u8]) -> impl FnMut(u64, usize) -> Vec<u8> + '_ {
        move |offset, length| {
            let start = (offset as usize).min(bytes.len());
            let end = (start + length).min(bytes.len());
            bytes[start..end].to_vec()
        }
    }

    fn locate_bytes(bytes: &[u8]) -> Location {
        locate(bytes.len() as u64, &mut reader(bytes))
    }

    fn ranges(bytes: &[u8]) -> Vec<Range<u64>> {
        match locate_bytes(bytes) {
            Location::Ranges(ranges) => ranges,
            other => panic!("expected ranges, got {other:?}"),
        }
    }

    fn flac_with_streaminfo_md5(md5: [u8; 16]) -> Vec<u8> {
        let mut bytes = b"fLaC".to_vec();
        bytes.extend([0x80, 0, 0, 34]);
        bytes.extend((0u8..18).collect::<Vec<u8>>());
        bytes.extend(md5);
        bytes.extend([0xAA; 10]);
        bytes
    }

    fn md5_bytes() -> [u8; 16] {
        let mut md5 = [0u8; 16];
        for (index, byte) in md5.iter_mut().enumerate() {
            *byte = 0x10 + index as u8;
        }
        md5
    }

    #[test]
    fn flac_md5() {
        let bytes = flac_with_streaminfo_md5(md5_bytes());
        assert_eq!(
            locate_bytes(&bytes),
            Location::FlacMd5("101112131415161718191a1b1c1d1e1f".into())
        );
    }

    #[test]
    fn flac_zero_md5() {
        let mut bytes = b"fLaC".to_vec();
        bytes.extend([0x00, 0, 0, 34]);
        bytes.extend([0u8; 34]);
        bytes.extend([0x84, 0, 0, 3]);
        bytes.extend(b"abc");
        bytes.extend([0xAA; 5]);
        assert_eq!(ranges(&bytes), vec![49..54]);
    }

    #[test]
    fn flac_after_id3() {
        let mut bytes = b"ID3".to_vec();
        bytes.extend([3, 0, 0, 0, 0, 0, 6]);
        bytes.extend([0u8; 6]);
        bytes.extend(flac_with_streaminfo_md5(md5_bytes()));
        assert_eq!(
            locate_bytes(&bytes),
            Location::FlacMd5("101112131415161718191a1b1c1d1e1f".into())
        );
    }

    #[test]
    fn wav_data_chunk() {
        let mut bytes = b"RIFF".to_vec();
        bytes.extend(0u32.to_le_bytes());
        bytes.extend(b"WAVE");
        bytes.extend(b"fmt ");
        bytes.extend(16u32.to_le_bytes());
        bytes.extend([0u8; 16]);
        bytes.extend(b"LIST");
        bytes.extend(5u32.to_le_bytes());
        bytes.extend([0u8; 5]);
        bytes.push(0);
        bytes.extend(b"data");
        bytes.extend(8u32.to_le_bytes());
        bytes.extend([0xAA; 8]);
        assert_eq!(ranges(&bytes), vec![58..66]);
    }

    #[test]
    fn aiff_ssnd() {
        let mut bytes = b"FORM".to_vec();
        bytes.extend(0u32.to_be_bytes());
        bytes.extend(b"AIFF");
        bytes.extend(b"COMM");
        bytes.extend(18u32.to_be_bytes());
        bytes.extend([0u8; 18]);
        bytes.extend(b"SSND");
        bytes.extend(12u32.to_be_bytes());
        bytes.extend([0xAA; 12]);
        assert_eq!(ranges(&bytes), vec![46..58]);
    }

    #[test]
    fn mp4_mdat() {
        let mut bytes = 16u32.to_be_bytes().to_vec();
        bytes.extend(b"ftyp");
        bytes.extend([0u8; 8]);
        bytes.extend(12u32.to_be_bytes());
        bytes.extend(b"moov");
        bytes.extend([0u8; 4]);
        bytes.extend(20u32.to_be_bytes());
        bytes.extend(b"mdat");
        bytes.extend([0xAA; 12]);
        assert_eq!(ranges(&bytes), vec![36..48]);
    }

    #[test]
    fn mp4_largesize() {
        let mut bytes = 16u32.to_be_bytes().to_vec();
        bytes.extend(b"ftyp");
        bytes.extend([0u8; 8]);
        bytes.extend(1u32.to_be_bytes());
        bytes.extend(b"mdat");
        bytes.extend(28u64.to_be_bytes());
        bytes.extend([0xAA; 12]);
        assert_eq!(ranges(&bytes), vec![32..44]);
    }

    #[test]
    fn mp3_id3_and_v1() {
        let mut bytes = b"ID3".to_vec();
        bytes.extend([3, 0, 0, 0, 0, 0, 4]);
        bytes.extend([0u8; 4]);
        bytes.extend([0xFF, 0xFB]);
        bytes.extend([0xAA; 6]);
        bytes.extend(b"TAG");
        bytes.extend([0u8; 125]);
        assert_eq!(bytes.len(), 150);
        assert_eq!(ranges(&bytes), vec![14..22]);
    }

    #[test]
    fn mp3_ape_and_v1() {
        let mut bytes = vec![0xFF, 0xFB];
        bytes.extend([0xAA; 6]);
        bytes.extend([0xBB; 10]);
        bytes.extend(b"APETAGEX");
        bytes.extend(2000u32.to_le_bytes());
        bytes.extend(42u32.to_le_bytes());
        bytes.extend(1u32.to_le_bytes());
        bytes.extend(0u32.to_le_bytes());
        bytes.extend([0u8; 8]);
        bytes.extend(b"TAG");
        bytes.extend([0u8; 125]);
        assert_eq!(ranges(&bytes), vec![0..8]);
    }

    #[test]
    fn unknown() {
        assert_eq!(ranges(b"hello world"), vec![0..11]);
    }

    #[test]
    fn flac_truncated() {
        let mut bytes = b"fLaC".to_vec();
        bytes.extend([0x80, 0, 0, 34]);
        bytes.extend([0u8; 10]);
        assert_eq!(ranges(&bytes), vec![0..18]);
    }

    #[test]
    fn wav_without_data() {
        let mut bytes = b"RIFF".to_vec();
        bytes.extend(0u32.to_le_bytes());
        bytes.extend(b"WAVE");
        bytes.extend(b"fmt ");
        bytes.extend(4u32.to_le_bytes());
        bytes.extend([0u8; 4]);
        assert_eq!(ranges(&bytes), vec![0..24]);
    }

    #[test]
    fn empty() {
        assert_eq!(
            locate(0, &mut |_, _| Vec::new()),
            Location::Ranges(Vec::new())
        );
    }
}
