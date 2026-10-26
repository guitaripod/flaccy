//! The REST endpoints: routing, authentication and the dispatch to handlers.

mod annotate;
mod browse;
mod identity;
mod lists;
mod media;
mod model;
mod now_playing;
mod playlists;
mod queue;
mod system;
pub mod userview;
mod writes;

use std::sync::Arc;
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
use crate::security::Principal;
use crate::state::AppState;
use crate::throttle;

pub use identity::RestIdentities;
use userview::UserView;

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
    pub principal: Principal,
    pub view: Arc<UserView>,
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
    let holder = match identity::key_holder(&state, params.get("apiKey")).await {
        Ok(holder) => holder,
        Err(error) => return render_error(format, &error),
    };
    let verified = state.0.login_throttle.attempt(address, Instant::now(), || {
        auth::authenticate_with(&params, state.credentials().as_ref(), holder.as_ref().map(identity::Presented::name))
    });
    let login = match verified {
        Ok(login) => login,
        Err(error) => return reply::render(format, reply::failure(&error)),
    };
    let identity = match identity::resolve(&state, &login, holder).await {
        Ok(identity) => identity,
        Err(error) => return render_error(format, &error),
    };
    let view = match user_view(&state, &method, &identity.principal).await {
        Ok(view) => view,
        Err(error) => return render_error(format, &error),
    };
    let call = Call {
        state: &state,
        params: &params,
        method: &method,
        username: identity.username,
        principal: identity.principal,
        view,
    };
    match dispatch(&call, &parts).await {
        Ok(Outcome::Fields(fields)) => reply::render(format, reply::success(fields)),
        Ok(Outcome::Raw(response)) => response,
        Err(error) => render_error(format, &error),
    }
}

const MEDIA_METHODS: [&str; 3] = ["stream", "download", "getcoverart"];

/// The user's stars, ratings and plays for the calls that show them; the calls that only move bytes get none.
async fn user_view(state: &AppState, method: &str, principal: &Principal) -> Result<Arc<UserView>, ApiError> {
    if MEDIA_METHODS.contains(&method.to_ascii_lowercase().as_str()) {
        return Ok(Arc::default());
    }
    state.0.views.get(&state.0.sync, &principal.user).await.map_err(|error| {
        ApiError::generic(format!(
            "Could not read what this user starred, rated and played: {error} Check that the server's data folder is readable, then try again"
        ))
    })
}

fn render_error(format: Format, error: &ApiError) -> Response {
    reply::render(format, reply::failure(error))
}

async fn dispatch(call: &Call<'_>, parts: &Parts) -> Result<Outcome, ApiError> {
    let name = call.method.to_ascii_lowercase();
    let fields = match name.as_str() {
        "stream" => return media::stream(call, parts).await,
        "download" => return media::download(call, parts).await,
        "getcoverart" => return media::cover_art(call).await,
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
        "scrobble" => annotate::scrobble(call).await?,
        "star" => annotate::star(call, true).await?,
        "unstar" => annotate::star(call, false).await?,
        "setrating" => annotate::set_rating(call).await?,
        "getplaylists" => playlists::list(call).await?,
        "getplaylist" => playlists::get(call).await?,
        "createplaylist" => playlists::create(call).await?,
        "updateplaylist" => playlists::update(call).await?,
        "deleteplaylist" => playlists::delete(call).await?,
        "getplayqueue" => queue::get(call).await?,
        "saveplayqueue" => queue::save(call).await?,
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

