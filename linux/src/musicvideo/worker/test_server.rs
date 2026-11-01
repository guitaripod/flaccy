//! A throwaway HTTP server for the download tests: it serves one body, with
//! ranges, or misbehaves in one chosen way.

use std::io::{BufRead, BufReader, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

#[derive(Clone, Copy)]
pub enum Mode {
    Serve,
    IgnoreRange,
    CutShort,
    Refuse(u16),
    FailOnce(u16),
}

pub struct Stub {
    pub url: String,
    pub hits: Arc<AtomicUsize>,
}

pub fn payload(length: usize) -> Vec<u8> {
    (0..length).map(|index| (index % 251) as u8).collect()
}

pub fn serve(mode: Mode, body: Vec<u8>) -> Stub {
    let listener = TcpListener::bind("127.0.0.1:0").expect("stub binds");
    let url = format!("http://{}/video", listener.local_addr().unwrap());
    let hits = Arc::new(AtomicUsize::new(0));
    let counted = Arc::clone(&hits);
    std::thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            let hit = counted.fetch_add(1, Ordering::SeqCst);
            answer(stream, mode, &body, hit);
        }
    });
    Stub { url, hits }
}

fn answer(mut stream: TcpStream, mode: Mode, body: &[u8], hit: usize) {
    let mut reader = BufReader::new(stream.try_clone().unwrap());
    let mut range = None;
    loop {
        let mut line = String::new();
        if reader.read_line(&mut line).unwrap_or(0) == 0 || line == "\r\n" {
            break;
        }
        if let Some(value) = line.to_ascii_lowercase().strip_prefix("range: bytes=") {
            let (first, last) = value.trim().split_once('-').unwrap();
            range = Some((first.parse::<usize>().unwrap(), last.parse::<usize>().unwrap()));
        }
    }
    let refusal = match mode {
        Mode::Refuse(code) => Some(code),
        Mode::FailOnce(code) if hit == 0 => Some(code),
        _ => None,
    };
    if let Some(code) = refusal {
        let _ = write!(stream, "HTTP/1.1 {code} No\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        return;
    }
    match (mode, range) {
        (Mode::IgnoreRange, _) | (_, None) => {
            let _ = write!(
                stream,
                "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                body.len()
            );
            let _ = stream.write_all(body);
        }
        (_, Some((first, last))) => {
            if first >= body.len() {
                let _ = write!(stream, "HTTP/1.1 416 Range\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
                return;
            }
            let last = last.min(body.len() - 1);
            let slice = &body[first..=last];
            let _ = write!(
                stream,
                "HTTP/1.1 206 Partial\r\nContent-Range: bytes {first}-{last}/{}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                body.len(),
                slice.len()
            );
            let sent = if matches!(mode, Mode::CutShort) { slice.len() / 2 } else { slice.len() };
            let _ = stream.write_all(&slice[..sent]);
        }
    }
}

pub fn scratch(name: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!("flaccy-download-{}-{name}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

