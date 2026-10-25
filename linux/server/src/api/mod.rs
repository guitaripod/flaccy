//! The REST endpoints: routing, authentication and the dispatch to handlers.

mod annotate;
mod browse;
mod lists;
mod media;
mod model;
mod playlists;
mod system;

use std::time::Instant;

use axum::extract::{Path, Request, State};
use axum::http::request::Parts;
use axum::response::Response;
use axum::routing::any;
use axum::Router;
use serde_json::{Map, Value};

use crate::auth;
use crate::error::ApiError;
use crate::reply::{self, Format};
use crate::request::Params;
use crate::state::AppState;
use crate::throttle;

const MAX_FORM_BYTES: usize = 1 << 20;

/// The fields an endpoint adds to the envelope.
pub(crate) type Fields = Map<String, Value>;

/// What an endpoint produces: fields for the envelope, or a finished response
/// such as audio or a picture.
pub(crate) enum Outcome {
    Fields(Fields),
    Raw(Response),
}

/// One call as the handlers see it.
pub(crate) struct Call<'a> {
    pub state: &'a AppState,
    pub params: &'a Params,
    pub method: &'a str,
    pub username: String,
}

impl<'a> Call<'a> {
    /// The first value of a parameter the call cannot do without.
    pub fn require(&self, name: &str) -> Result<&'a str, ApiError> {
        self.params
            .get(name)
            .filter(|value| !value.is_empty())
            .ok_or_else(|| ApiError::missing_parameter(self.method, name))
    }
}

/// The router that serves `/rest/<method>` and `/rest/<method>.view` for GET and POST.
pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/rest/{method}", any(entry))
        .with_state(state)
}

async fn entry(State(state): State<AppState>, Path(raw_method): Path<String>, request: Request) -> Response {
    let (parts, body) = request.into_parts();
    let body = axum::body::to_bytes(body, MAX_FORM_BYTES).await.unwrap_or_default();
    let params = Params::parse(parts.uri.query(), &body);
    let format = reply::format_of(&params);
    let method = raw_method.strip_suffix(".view").unwrap_or(&raw_method).to_string();

    let address = throttle::client_address(&parts, state.0.config.behind_proxy);
    let verified = state.0.login_throttle.attempt(address, Instant::now(), || {
        let credentials = state.credentials();
        auth::authenticate(&params, credentials.as_ref())?;
        Ok(credentials.map(|credentials| credentials.username).unwrap_or_default())
    });
    let username = match verified {
        Ok(username) => username,
        Err(error) => return reply::render(format, reply::failure(&error)),
    };
    let call = Call {
        state: &state,
        params: &params,
        method: &method,
        username,
    };
    match dispatch(&call, &parts).await {
        Ok(Outcome::Fields(fields)) => reply::render(format, reply::success(fields)),
        Ok(Outcome::Raw(response)) => response,
        Err(error) => render_error(format, &error),
    }
}

fn render_error(format: Format, error: &ApiError) -> Response {
    reply::render(format, reply::failure(error))
}

async fn dispatch(call: &Call<'_>, parts: &Parts) -> Result<Outcome, ApiError> {
    let name = call.method.to_ascii_lowercase();
    let fields = match name.as_str() {
        "stream" => return media::stream(call, parts).await,
        "download" => return media::download(call, parts).await,
        "getcoverart" => return media::cover_art(call),
        "ping" => Fields::new(),
        "getlicense" => system::license(),
        "getopensubsonicextensions" => system::extensions(),
        "getuser" => system::user(call)?,
        "getmusicfolders" => system::music_folders(),
        "getindexes" => browse::indexes(call),
        "getartists" => browse::artists(call),
        "getartist" => browse::artist(call)?,
        "getalbum" => browse::album(call)?,
        "getsong" => browse::song(call)?,
        "getalbumlist2" => lists::album_list(call)?,
        "getrandomsongs" => lists::random_songs(call),
        "search3" => lists::search(call),
        "getstarred2" => lists::starred(call),
        "getlyricsbysongid" => browse::lyrics(call)?,
        "scrobble" => annotate::scrobble(call)?,
        "star" => annotate::star(call, true)?,
        "unstar" => annotate::star(call, false)?,
        "setrating" => annotate::set_rating(call)?,
        "getplaylists" => playlists::list(call),
        "getplaylist" => playlists::get(call)?,
        "createplaylist" => playlists::create(call)?,
        "updateplaylist" => playlists::update(call)?,
        "deleteplaylist" => playlists::delete(call)?,
        "getplayqueue" => playlists::play_queue(call),
        "saveplayqueue" => playlists::save_play_queue(call)?,
        _ => {
            return Err(ApiError::generic(format!(
                "'{}' is not implemented by flaccy-server; use a client call it supports such as getAlbumList2, getAlbum, stream or getCoverArt",
                call.method
            )))
        }
    };
    Ok(Outcome::Fields(fields))
}

/// A single-key field map.
pub(crate) fn one(key: &str, value: Value) -> Fields {
    let mut fields = Fields::new();
    fields.insert(key.to_string(), value);
    fields
}

/// An empty body for the Subsonic calls that only answer `ok`.
pub(crate) fn ok() -> Fields {
    Fields::new()
}

