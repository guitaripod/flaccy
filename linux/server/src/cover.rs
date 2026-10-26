//! Cover pictures: the stored album cover, the one embedded in a file, and
//! resized copies cached on disk.

use std::fs;
use std::io::Cursor;
use std::path::{Path, PathBuf};

use image::imageops::FilterType;
use image::{DynamicImage, ImageReader, Limits};
use lofty::file::TaggedFileExt;
use lofty::picture::PictureType;
use tokio::sync::Semaphore;

use crate::ids;

const JPEG_QUALITY: u8 = 85;

/// The media type a picture's leading bytes say it is.
pub fn content_type(bytes: &[u8]) -> &'static str {
    if bytes.starts_with(&[0xFF, 0xD8, 0xFF]) {
        "image/jpeg"
    } else if bytes.starts_with(&[0x89, b'P', b'N', b'G']) {
        "image/png"
    } else if bytes.starts_with(b"GIF8") {
        "image/gif"
    } else if bytes.len() > 12 && &bytes[..4] == b"RIFF" && &bytes[8..12] == b"WEBP" {
        "image/webp"
    } else {
        "application/octet-stream"
    }
}

/// The front cover embedded in the audio file at `path`, else its first picture.
pub fn embedded_picture(path: &Path) -> Option<Vec<u8>> {
    let tagged = lofty::probe::Probe::open(path).ok()?.read().ok()?;
    let tag = tagged.primary_tag().or_else(|| tagged.first_tag())?;
    tag.pictures()
        .iter()
        .find(|picture| picture.pic_type() == PictureType::CoverFront)
        .or_else(|| tag.pictures().first())
        .map(|picture| picture.data().to_vec())
}

/// The widest or tallest side an uploaded or resized picture may have.
pub const MAX_SIDE: u32 = 8192;
/// The most pixels an uploaded or resized picture may have: 16 megapixels.
pub const MAX_PIXELS: u64 = 16_000_000;
/// The sizes a resized cover is cut to; a request is rounded up to the next one.
pub const SIZE_BUCKETS: [u32; 5] = [64, 128, 256, 512, 1024];
const MIN_REQUESTED_SIZE: u32 = 32;
const DECODE_ALLOC_BYTES: u64 = 128 * 1024 * 1024;
const CONCURRENT_RESIZES: usize = 2;

static RESIZE_PERMITS: Semaphore = Semaphore::const_new(CONCURRENT_RESIZES);

/// True when a picture of this size is within [`MAX_PIXELS`] and [`MAX_SIDE`].
pub fn within_limits(width: u32, height: u32) -> bool {
    width > 0 && height > 0 && width <= MAX_SIDE && height <= MAX_SIDE && u64::from(width) * u64::from(height) <= MAX_PIXELS
}

/// The width and height a picture's header declares, read without decoding any pixels.
pub fn dimensions(bytes: &[u8]) -> Option<(u32, u32)> {
    if bytes.starts_with(&[0x89, b'P', b'N', b'G']) {
        png_dimensions(bytes)
    } else if bytes.starts_with(&[0xFF, 0xD8, 0xFF]) {
        jpeg_dimensions(bytes)
    } else if bytes.len() > 12 && &bytes[..4] == b"RIFF" && &bytes[8..12] == b"WEBP" {
        webp_dimensions(bytes)
    } else {
        None
    }
}

/// The size in the IHDR chunk that must open a PNG.
fn png_dimensions(bytes: &[u8]) -> Option<(u32, u32)> {
    if bytes.get(12..16)? != b"IHDR" {
        return None;
    }
    let side = |at: usize| Some(u32::from_be_bytes(bytes.get(at..at + 4)?.try_into().ok()?));
    Some((side(16)?, side(20)?))
}

/// The size in the first start-of-frame segment of a JPEG, found by walking the segments before it.
fn jpeg_dimensions(bytes: &[u8]) -> Option<(u32, u32)> {
    let mut at = 2;
    while at + 4 <= bytes.len() {
        if bytes[at] != 0xFF {
            at += 1;
            continue;
        }
        let marker = bytes[at + 1];
        match marker {
            0xFF => at += 1,
            0x01 | 0xD0..=0xD8 => at += 2,
            0xD9 | 0xDA => return None,
            0xC0..=0xCF if !matches!(marker, 0xC4 | 0xC8 | 0xCC) => {
                let side = |from: usize| Some(u32::from(u16::from_be_bytes(bytes.get(from..from + 2)?.try_into().ok()?)));
                return Some((side(at + 7)?, side(at + 5)?));
            }
            _ => at += 2 + usize::from(u16::from_be_bytes([bytes[at + 2], bytes[at + 3]])),
        }
    }
    None
}

/// The canvas size in the first chunk of a WebP file: lossy, lossless or extended.
fn webp_dimensions(bytes: &[u8]) -> Option<(u32, u32)> {
    let le24 = |at: usize| Some(u32::from_le_bytes([*bytes.get(at)?, *bytes.get(at + 1)?, *bytes.get(at + 2)?, 0]));
    match bytes.get(12..16)? {
        b"VP8X" => Some((le24(24)? + 1, le24(27)? + 1)),
        b"VP8L" if *bytes.get(20)? == 0x2F => {
            let bits = u32::from_le_bytes([*bytes.get(21)?, *bytes.get(22)?, *bytes.get(23)?, *bytes.get(24)?]);
            Some(((bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1))
        }
        b"VP8 " if bytes.get(23..26)? == [0x9D, 0x01, 0x2A] => {
            let side = |at: usize| Some(u32::from(u16::from_le_bytes([*bytes.get(at)?, *bytes.get(at + 1)?]) & 0x3FFF));
            Some((side(26)?, side(28)?))
        }
        _ => None,
    }
}

/// The bucket a requested size is cut to: at least 32, at most 1024, rounded up to 64, 128, 256, 512 or 1024.
pub fn size_bucket(requested: u32) -> u32 {
    let wanted = requested.max(MIN_REQUESTED_SIZE);
    SIZE_BUCKETS.into_iter().find(|bucket| *bucket >= wanted).unwrap_or(SIZE_BUCKETS[SIZE_BUCKETS.len() - 1])
}

/// A JPEG of `source` that fits in a box of the bucket `size` rounds up to, keeping its
/// aspect, cached in `cache_dir`. The cache name carries a hash of the source, so a new
/// cover never meets an old resize. A picture already small enough, one beyond
/// [`MAX_PIXELS`] or [`MAX_SIDE`], or one the image decoder cannot read, comes back as
/// it is with its own media type. Decoding runs on the blocking pool, two at a time.
pub async fn resized(cache_dir: PathBuf, cover_id: String, size: u32, source: Vec<u8>) -> (Vec<u8>, &'static str) {
    let size = size_bucket(size);
    let digest = ids::sha256_hex(&source)[..16].to_owned();
    let cached = cache_dir.join(format!("{cover_id}-{size}-{digest}.jpg"));
    if let Ok(bytes) = tokio::fs::read(&cached).await {
        return (bytes, "image/jpeg");
    }
    let Ok(_permit) = RESIZE_PERMITS.acquire().await else {
        return untouched(source);
    };
    let fallback = source.clone();
    let work = move || resize_and_cache(&cache_dir, &cached, size, source);
    tokio::task::spawn_blocking(work).await.unwrap_or_else(|_| untouched(fallback))
}

fn untouched(source: Vec<u8>) -> (Vec<u8>, &'static str) {
    let kind = content_type(&source);
    (source, kind)
}

fn resize_and_cache(cache_dir: &Path, cached: &Path, size: u32, source: Vec<u8>) -> (Vec<u8>, &'static str) {
    let Some((width, height)) = dimensions(&source).filter(|(width, height)| within_limits(*width, *height)) else {
        return untouched(source);
    };
    if width <= size && height <= size {
        return untouched(source);
    }
    let Some(decoded) = decode_limited(&source) else {
        return untouched(source);
    };
    let rgb = DynamicImage::ImageRgb8(decoded.resize(size, size, FilterType::Lanczos3).to_rgb8());
    let mut encoded = Vec::new();
    let encoder = image::codecs::jpeg::JpegEncoder::new_with_quality(&mut encoded, JPEG_QUALITY);
    if rgb.write_with_encoder(encoder).is_err() {
        return untouched(source);
    }
    store_in_cache(cache_dir, cached, &encoded);
    (encoded, "image/jpeg")
}

fn decode_limited(source: &[u8]) -> Option<DynamicImage> {
    let mut limits = Limits::default();
    limits.max_alloc = Some(DECODE_ALLOC_BYTES);
    limits.max_image_width = Some(MAX_SIDE);
    limits.max_image_height = Some(MAX_SIDE);
    let mut reader = ImageReader::new(Cursor::new(source)).with_guessed_format().ok()?;
    reader.limits(limits);
    reader.decode().ok()
}

fn store_in_cache(cache_dir: &Path, cached: &Path, encoded: &[u8]) {
    if fs::create_dir_all(cache_dir).is_err() {
        return;
    }
    let temporary = cached.with_extension("tmp");
    if fs::write(&temporary, encoded).is_ok() {
        let _ = fs::rename(&temporary, cached);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::ImageFormat;

    fn png(width: u32, height: u32) -> Vec<u8> {
        let image = image::RgbImage::from_pixel(width, height, image::Rgb([200, 30, 30]));
        let mut bytes = Vec::new();
        image::DynamicImage::ImageRgb8(image)
            .write_to(&mut std::io::Cursor::new(&mut bytes), ImageFormat::Png)
            .unwrap();
        bytes
    }

    fn jpeg(width: u32, height: u32) -> Vec<u8> {
        let image = image::RgbImage::from_pixel(width, height, image::Rgb([10, 200, 30]));
        let mut bytes = Vec::new();
        image::DynamicImage::ImageRgb8(image)
            .write_to(&mut std::io::Cursor::new(&mut bytes), ImageFormat::Jpeg)
            .unwrap();
        bytes
    }

    #[test]
    fn bytes_are_recognised_by_their_signature() {
        assert_eq!(content_type(&png(2, 2)), "image/png");
        assert_eq!(content_type(&[0xFF, 0xD8, 0xFF, 0xE0]), "image/jpeg");
        assert_eq!(content_type(b"nope"), "application/octet-stream");
    }

    #[tokio::test]
    async fn a_big_cover_shrinks_keeping_its_aspect_and_is_cached() {
        let dir = std::env::temp_dir().join(format!("flaccy-cover-{}", std::process::id()));
        let source = png(400, 200);
        let (bytes, kind) = resized(dir.clone(), "al-test".into(), 100, source.clone()).await;
        assert_eq!(kind, "image/jpeg");
        let shrunk = image::load_from_memory(&bytes).unwrap();
        assert_eq!((shrunk.width(), shrunk.height()), (128, 64));
        assert_eq!(fs::read_dir(&dir).unwrap().count(), 1);
        assert_eq!(resized(dir.clone(), "al-test".into(), 100, source).await.0, bytes);
        fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn a_small_cover_is_returned_untouched() {
        let dir = std::env::temp_dir().join("flaccy-cover-small");
        let source = png(20, 20);
        assert_eq!(resized(dir, "al-x".into(), 100, source.clone()).await, (source, "image/png"));
    }

    #[tokio::test]
    async fn a_picture_declaring_a_bomb_is_never_decoded_and_comes_back_as_it_is() {
        let dir = std::env::temp_dir().join("flaccy-cover-bomb");
        let mut bomb = png(2, 2);
        bomb[16..20].copy_from_slice(&12_000u32.to_be_bytes());
        bomb[20..24].copy_from_slice(&12_000u32.to_be_bytes());
        assert_eq!(dimensions(&bomb), Some((12_000, 12_000)));
        assert_eq!(resized(dir.clone(), "al-bomb".into(), 64, bomb.clone()).await, (bomb, "image/png"));
        assert!(!dir.exists());
    }

    #[tokio::test]
    async fn at_most_two_resizes_run_at_once() {
        let dir = std::env::temp_dir().join(format!("flaccy-cover-gate-{}", std::process::id()));
        let first = RESIZE_PERMITS.acquire().await.unwrap();
        let second = RESIZE_PERMITS.acquire().await.unwrap();
        let waiting = tokio::spawn(resized(dir.clone(), "al-gate".into(), 64, png(400, 200)));
        tokio::time::sleep(std::time::Duration::from_millis(150)).await;
        assert!(!waiting.is_finished());
        drop(first);
        let (_, kind) = tokio::time::timeout(std::time::Duration::from_secs(10), waiting).await.unwrap().unwrap();
        assert_eq!(kind, "image/jpeg");
        drop(second);
        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    fn requested_sizes_round_up_to_a_bucket() {
        let buckets: Vec<u32> = [0, 1, 32, 33, 64, 65, 200, 512, 513, 1024, 4096].map(size_bucket).to_vec();
        assert_eq!(buckets, [64, 64, 64, 64, 64, 128, 256, 512, 1024, 1024, 1024]);
    }

    #[test]
    fn dimensions_come_from_the_header_and_limits_apply() {
        assert_eq!(dimensions(&png(40, 30)), Some((40, 30)));
        assert_eq!(dimensions(&jpeg(60, 20)), Some((60, 20)));
        assert_eq!(dimensions(b"not an image"), None);
        assert!(within_limits(4000, 4000));
        assert!(!within_limits(4001, 4000));
        assert!(!within_limits(8193, 10));
        assert!(!within_limits(0, 10));
    }

    #[test]
    fn webp_headers_are_read_in_all_three_flavours() {
        let mut extended = b"RIFF\0\0\0\0WEBPVP8X\x0a\0\0\0\0\0\0\0".to_vec();
        extended.extend_from_slice(&[0x0F, 0x00, 0x00, 0x1F, 0x00, 0x00]);
        assert_eq!(dimensions(&extended), Some((16, 32)));
        let mut lossless = b"RIFF\0\0\0\0WEBPVP8L\x05\0\0\0".to_vec();
        lossless.push(0x2F);
        let packed: u32 = 99 | (49 << 14);
        lossless.extend_from_slice(&packed.to_le_bytes());
        assert_eq!(dimensions(&lossless), Some((100, 50)));
        let mut lossy = b"RIFF\0\0\0\0WEBPVP8 \x0a\0\0\0\0\0\0".to_vec();
        lossy.extend_from_slice(&[0x9D, 0x01, 0x2A, 0xC8, 0x00, 0x64, 0x00]);
        assert_eq!(dimensions(&lossy), Some((200, 100)));
    }
}
