use crate::double::Shared;
use axum::body::Body;
use axum::extract::{Request, State};
use axum::http::{header, HeaderValue};
use axum::middleware::Next;
use axum::response::Response;

#[derive(Default)]
pub struct Chaos {
    pub cut_remaining: u32,
    pub cut_path: String,
    pub garbage: bool,
}

pub async fn disturb(State(shared): State<Shared>, request: Request, next: Next) -> Response {
    let path = request.uri().path().to_owned();
    let response = next.run(request).await;
    let (cut, garbage) = {
        let mut state = shared.lock().unwrap();
        let chaos = &mut state.chaos;
        let cut = chaos.cut_remaining > 0 && path.contains(&chaos.cut_path);
        if cut {
            chaos.cut_remaining -= 1;
        }
        (cut, chaos.garbage)
    };
    if garbage && response.status().is_success() {
        return garbled(response);
    }
    if cut {
        return truncated(response).await;
    }
    response
}

fn garbled(response: Response) -> Response {
    let (mut parts, _) = response.into_parts();
    let body = b"{\"results\":}".to_vec();
    parts.headers.remove(header::CONTENT_ENCODING);
    parts.headers.insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static("application/json"),
    );
    parts
        .headers
        .insert(header::CONTENT_LENGTH, HeaderValue::from(body.len()));
    Response::from_parts(parts, Body::from(body))
}

async fn truncated(response: Response) -> Response {
    let (mut parts, body) = response.into_parts();
    let bytes = axum::body::to_bytes(body, usize::MAX).await.unwrap();
    if bytes.is_empty() {
        return Response::from_parts(parts, Body::from(bytes));
    }
    let keep = rand::random::<u64>() as usize % bytes.len();
    parts.headers.remove(header::CONTENT_LENGTH);
    let pieces: Vec<Result<axum::body::Bytes, std::io::Error>> = vec![
        Ok(bytes.slice(..keep)),
        Err(std::io::Error::new(
            std::io::ErrorKind::ConnectionReset,
            "cut",
        )),
    ];
    Response::from_parts(parts, Body::from_stream(futures_util::stream::iter(pieces)))
}
