//! Streaming, downloads, conversion and cover pictures.

use axum::http::StatusCode;

use super::TestServer;

fn stream_uri(id: &str) -> String {
    format!("/rest/stream?{}&id={id}", TestServer::login())
}

async fn first_song(server: &TestServer) -> (String, Vec<u8>) {
    let id = server.song_id("Opening").await;
    let bytes = std::fs::read(server.music().join("Drill Band/Rough Cuts/01 Opening.wav")).unwrap();
    (id, bytes)
}

#[tokio::test]
async fn stream_sends_the_original_file_with_range_headers() {
    let server = TestServer::new();
    server.standard_library();
    let (id, original) = first_song(&server).await;
    let full = server.get(&stream_uri(&id)).await;
    assert_eq!(full.status, StatusCode::OK);
    assert_eq!(full.body, original);
    assert_eq!(full.header("accept-ranges"), "bytes");
    assert!(!full.header("last-modified").is_empty());
    assert_eq!(full.header("content-length"), original.len().to_string());

    let head = server
        .send(
            axum::http::Request::builder()
                .method("HEAD")
                .uri(stream_uri(&id))
                .body(axum::body::Body::empty())
                .unwrap(),
        )
        .await;
    assert_eq!(head.status, StatusCode::OK);
    assert!(head.body.is_empty());
    assert_eq!(head.header("content-length"), original.len().to_string());
}

#[tokio::test]
async fn a_range_request_answers_206_with_content_range() {
    let server = TestServer::new();
    server.standard_library();
    let (id, original) = first_song(&server).await;
    let partial = server.get_with(&stream_uri(&id), &[("range", "bytes=10-109")]).await;
    assert_eq!(partial.status, StatusCode::PARTIAL_CONTENT);
    assert_eq!(partial.header("content-range"), format!("bytes 10-109/{}", original.len()));
    assert_eq!(partial.body, original[10..110].to_vec());

    let tail = server.get_with(&stream_uri(&id), &[("range", "bytes=-50")]).await;
    assert_eq!(tail.status, StatusCode::PARTIAL_CONTENT);
    assert_eq!(tail.body, original[original.len() - 50..].to_vec());

    let beyond = server
        .get_with(&stream_uri(&id), &[("range", &format!("bytes={}-", original.len() + 5))])
        .await;
    assert_eq!(beyond.status, StatusCode::RANGE_NOT_SATISFIABLE);
}

#[tokio::test]
async fn if_range_with_a_stale_date_returns_the_whole_file() {
    let server = TestServer::new();
    server.standard_library();
    let (id, original) = first_song(&server).await;
    let last_modified = server.get(&stream_uri(&id)).await.header("last-modified").to_string();

    let fresh = server
        .get_with(&stream_uri(&id), &[("range", "bytes=0-9"), ("if-range", &last_modified)])
        .await;
    assert_eq!(fresh.status, StatusCode::PARTIAL_CONTENT);
    assert_eq!(fresh.body.len(), 10);

    let stale = server
        .get_with(
            &stream_uri(&id),
            &[("range", "bytes=0-9"), ("if-range", "Thu, 01 Jan 1970 00:00:00 GMT")],
        )
        .await;
    assert_eq!(stale.status, StatusCode::OK);
    assert_eq!(stale.body, original);
    assert!(stale.headers.get("content-range").is_none());
}

#[tokio::test]
async fn a_file_removed_after_the_scan_is_reported_not_crashed_on() {
    let server = TestServer::new();
    server.standard_library();
    let (id, _) = first_song(&server).await;
    std::fs::remove_file(server.music().join("Drill Band/Rough Cuts/01 Opening.wav")).unwrap();
    let reply = server.get(&format!("{}&f=json", stream_uri(&id))).await;
    assert_eq!(reply.status, StatusCode::OK);
    assert!(reply.text().contains("\"code\":70"), "{}", reply.text());
    let unknown = server.get(&format!("{}&f=json", stream_uri("s999999"))).await;
    assert!(unknown.text().contains("\"code\":70"));
}

#[tokio::test]
async fn download_is_the_raw_file_as_an_attachment() {
    let server = TestServer::new();
    server.standard_library();
    let (id, original) = first_song(&server).await;
    let reply = server
        .get(&format!("/rest/download?{}&id={id}", TestServer::login()))
        .await;
    assert_eq!(reply.status, StatusCode::OK);
    assert_eq!(reply.body, original);
    assert!(reply.header("content-disposition").starts_with("attachment; filename=\"01 Opening.wav\""));
}

#[tokio::test]
async fn raw_format_and_a_zero_bit_rate_stay_untouched() {
    let server = TestServer::with_ffmpeg("/nonexistent/ffmpeg");
    server.standard_library();
    let (id, original) = first_song(&server).await;
    for extra in ["format=raw", "maxBitRate=0", "format=raw&maxBitRate=0&estimateContentLength=true"] {
        let reply = server.get(&format!("{}&{extra}", stream_uri(&id))).await;
        assert_eq!(reply.body, original, "{extra}");
    }
}

#[tokio::test]
async fn a_missing_ffmpeg_answers_error_0_saying_to_install_it() {
    let server = TestServer::with_ffmpeg("/nonexistent/ffmpeg");
    server.standard_library();
    let (id, _) = first_song(&server).await;
    let reply = server.get(&format!("{}&f=json&format=mp3", stream_uri(&id))).await;
    let answer: serde_json::Value = serde_json::from_slice(&reply.body).unwrap();
    assert_eq!(answer["subsonic-response"]["error"]["code"], 0);
    let message = answer["subsonic-response"]["error"]["message"].as_str().unwrap();
    assert!(message.contains("ffmpeg") && message.contains("install"), "{message}");

    let bad_format = server.get(&format!("{}&f=json&format=wma", stream_uri(&id))).await;
    assert!(bad_format.text().contains("use raw, mp3, opus, aac or mp4"));
}

fn ffmpeg_present() -> bool {
    std::process::Command::new("ffmpeg")
        .arg("-version")
        .output()
        .is_ok_and(|output| output.status.success())
}

#[tokio::test]
async fn ffmpeg_converts_to_the_format_asked_for() {
    if !ffmpeg_present() {
        return;
    }
    let server = TestServer::new();
    server.standard_library();
    let (id, original) = first_song(&server).await;

    let mp3 = server.get(&format!("{}&format=mp3&maxBitRate=96", stream_uri(&id))).await;
    assert_eq!(mp3.status, StatusCode::OK);
    assert_eq!(mp3.header("content-type"), "audio/mpeg");
    assert!(mp3.headers.get("content-length").is_none());
    assert!(!mp3.body.is_empty());
    assert!(mp3.body.starts_with(b"ID3") || mp3.body[0] == 0xFF, "not an mp3 stream");
    assert_ne!(mp3.body, original);

    let opus = server.get(&format!("{}&format=opus", stream_uri(&id))).await;
    assert_eq!(opus.header("content-type"), "audio/ogg");
    assert!(opus.body.starts_with(b"OggS"));

    let aac = server.get(&format!("{}&format=aac", stream_uri(&id))).await;
    assert_eq!(aac.header("content-type"), "audio/aac");
    assert!(aac.body.len() > 100 && aac.body[0] == 0xFF);

    let limited = server.get(&format!("{}&maxBitRate=64", stream_uri(&id))).await;
    assert_eq!(limited.header("content-type"), "audio/mpeg");
}

fn png(width: u32, height: u32) -> Vec<u8> {
    let image = image::RgbImage::from_pixel(width, height, image::Rgb([20, 120, 220]));
    let mut bytes = Vec::new();
    image::DynamicImage::ImageRgb8(image)
        .write_to(&mut std::io::Cursor::new(&mut bytes), image::ImageFormat::Png)
        .unwrap();
    bytes
}

#[tokio::test]
async fn cover_art_serves_the_stored_cover_and_resizes_it_into_the_cache() {
    let server = TestServer::new();
    server.standard_library();
    let album = server.album_id("Rough Cuts").await;
    let uri = format!("/rest/getCoverArt?{}&id={album}", TestServer::login());

    let none = server.get(&format!("{uri}&f=json")).await;
    assert!(none.text().contains("\"code\":70"), "{}", none.text());

    let cover = png(300, 150);
    server
        .state
        .db()
        .set_custom_cover(&[("Rough Cuts".to_string(), "Drill Band".to_string())], &cover)
        .unwrap();

    let original = server.get(&uri).await;
    assert_eq!(original.header("content-type"), "image/png");
    assert_eq!(original.body, cover);

    let small = server.get(&format!("{uri}&size=60")).await;
    assert_eq!(small.header("content-type"), "image/jpeg");
    let decoded = image::load_from_memory(&small.body).unwrap();
    assert_eq!((decoded.width(), decoded.height()), (60, 30));
    let cached = std::fs::read_dir(server.state.0.config.covers_dir()).unwrap().count();
    assert_eq!(cached, 1);

    let by_song = server.song_id("Opening").await;
    let song_cover = server
        .get(&format!("/rest/getCoverArt?{}&id={by_song}", TestServer::login()))
        .await;
    assert_eq!(song_cover.body, cover);

    let artist = server.json("getArtists", "").await;
    let first_artist = artist.envelope.artists.unwrap().index.unwrap()[0].artist.as_ref().unwrap()[0]
        .id
        .clone()
        .unwrap();
    let by_artist = server
        .get(&format!("/rest/getCoverArt?{}&id={first_artist}", TestServer::login()))
        .await;
    assert_eq!(by_artist.body, cover);
}
