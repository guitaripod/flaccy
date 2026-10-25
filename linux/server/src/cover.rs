//! Cover pictures: the stored album cover, the one embedded in a file, and
//! resized copies cached on disk.

use std::fs;
use std::path::Path;

use image::imageops::FilterType;
use image::DynamicImage;
use lofty::file::TaggedFileExt;
use lofty::picture::PictureType;

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

/// A JPEG of `source` that fits in a `size` by `size` box, keeping its aspect,
/// cached in `cache_dir`. The cache name carries a hash of the source, so a new
/// cover never meets an old resize. A picture already small enough, or one the
/// image decoder cannot read, comes back as it is with its own media type.
pub fn resized(cache_dir: &Path, cover_id: &str, size: u32, source: &[u8]) -> (Vec<u8>, &'static str) {
    let original = || (source.to_vec(), content_type(source));
    let digest = &ids::sha256_hex(source)[..16];
    let cached = cache_dir.join(format!("{cover_id}-{size}-{digest}.jpg"));
    if let Ok(bytes) = fs::read(&cached) {
        return (bytes, "image/jpeg");
    }
    let Ok(decoded) = image::load_from_memory(source) else {
        return original();
    };
    if decoded.width() <= size && decoded.height() <= size {
        return original();
    }
    let rgb = DynamicImage::ImageRgb8(decoded.resize(size, size, FilterType::Lanczos3).to_rgb8());
    let mut encoded = Vec::new();
    let encoder = image::codecs::jpeg::JpegEncoder::new_with_quality(&mut encoded, JPEG_QUALITY);
    if rgb.write_with_encoder(encoder).is_err() {
        return original();
    }
    if fs::create_dir_all(cache_dir).is_ok() {
        let temporary = cache_dir.join(format!(".{cover_id}-{size}-{digest}.tmp"));
        if fs::write(&temporary, &encoded).is_ok() {
            let _ = fs::rename(&temporary, &cached);
        }
    }
    (encoded, "image/jpeg")
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

    #[test]
    fn bytes_are_recognised_by_their_signature() {
        assert_eq!(content_type(&png(2, 2)), "image/png");
        assert_eq!(content_type(&[0xFF, 0xD8, 0xFF, 0xE0]), "image/jpeg");
        assert_eq!(content_type(b"nope"), "application/octet-stream");
    }

    #[test]
    fn a_big_cover_shrinks_keeping_its_aspect_and_is_cached() {
        let dir = std::env::temp_dir().join(format!("flaccy-cover-{}", std::process::id()));
        let source = png(400, 200);
        let (bytes, kind) = resized(&dir, "al-test", 100, &source);
        assert_eq!(kind, "image/jpeg");
        let shrunk = image::load_from_memory(&bytes).unwrap();
        assert_eq!((shrunk.width(), shrunk.height()), (100, 50));
        assert_eq!(fs::read_dir(&dir).unwrap().count(), 1);
        assert_eq!(resized(&dir, "al-test", 100, &source).0, bytes);
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_small_cover_is_returned_untouched() {
        let dir = std::env::temp_dir().join("flaccy-cover-small");
        let source = png(20, 20);
        assert_eq!(resized(&dir, "al-x", 100, &source), (source, "image/png"));
    }
}
