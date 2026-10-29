//! Running the server: open the state, start the background tasks, listen, and stop cleanly.
//!
//! `flaccy-server serve` and the embedded server both call [`run`], so they cannot drift apart.

use axum::Router;
use flaccy_library::logger;
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::net::TcpListener;
use tokio::sync::oneshot;

use crate::config::Config;
use crate::lastfm;
use crate::maintenance;
use crate::native;
use crate::net::guard::ConnectionAddr;
use crate::net::{self, descriptors, AllowedHosts, ConnectionLimits, EasyHandle, EasyListener, Limits, TailnetAddresses};
use crate::nightly;
use crate::refresh;
use crate::shutdown::{self, StopSignal};
use crate::state::{AppState, OpenOptions};

/// The address the configuration file defaults to; any other value is honoured as the only bind address.
const DEFAULT_ADDRESS: &str = "127.0.0.1";
const DEFAULT_FFMPEG: &str = "ffmpeg";
const FFMPEG_VARIABLE: &str = "FLACCY_SERVER_FFMPEG";

/// What `serve` tells a person whose port is taken.
pub(crate) const CONFIG_FILE_PORT_ADVICE: &str = "set a different `port` in the configuration file.";

/// What differs between `serve` and an embedded server.
pub(crate) struct Settings {
    pub open: OpenOptions,
    pub warn_without_account: bool,
    pub port_advice: &'static str,
}

/// What a caller learns once the server accepts connections.
pub(crate) struct Online {
    pub state: AppState,
    pub addresses: EasyHandle,
}

/// The program that converts audio: `FLACCY_SERVER_FFMPEG`, else `ffmpeg` from the `PATH`.
pub(crate) fn ffmpeg_program() -> String {
    std::env::var(FFMPEG_VARIABLE).unwrap_or_else(|_| DEFAULT_FFMPEG.to_owned())
}

/// Opens the state, runs the background tasks and serves until `stop` is raised, then closes the databases.
/// The caller holds the data-folder lock for as long as this runs. `online` is told once the listener is bound.
pub(crate) async fn run(
    config: Config,
    settings: Settings,
    stop: StopSignal,
    online: Option<oneshot::Sender<Online>>,
) -> Result<(), String> {
    let state = AppState::open_with(config, settings.open).await?;
    if settings.warn_without_account && state.credentials().is_none() {
        logger::warn(
            "server",
            "no account exists yet, so every OpenSubsonic login will be refused; run `flaccy-server password set` or `flaccy-server key add <name>` in another terminal, and `flaccy-server enroll --user <name>` to add a Flaccy device",
        );
    }
    let background = [
        tokio::spawn(refresh::keep_current(state.clone())),
        tokio::spawn(nightly::keep_backed_up(state.clone())),
        tokio::spawn(lastfm::run(state.clone())),
        tokio::spawn(maintenance::keep_tidy(state.clone())),
        state.0.live.shutdown_on(stop.clone()),
    ];
    let outcome = if state.0.config.address == DEFAULT_ADDRESS {
        serve_easy(state.clone(), &stop, online, settings.port_advice).await
    } else {
        serve_on_address(state.clone(), &stop).await
    };
    for task in &background {
        task.abort();
    }
    shutdown::close_databases(&state).await;
    outcome
}

async fn serve_easy(
    state: AppState,
    stop: &StopSignal,
    online: Option<oneshot::Sender<Online>>,
    port_advice: &str,
) -> Result<(), String> {
    let port = state.0.config.port;
    logger::info(
        "server",
        "the `address` setting is superseded by tailnet binding: the server listens on loopback and this machine's tailnet addresses; set `address` to another value to bind only that address",
    );
    let listener = EasyListener::bind(port).await.map_err(|err| {
        format!(
            "Could not listen on port {port}: {err}. Another program may be using that port; {port_advice}"
        )
    })?;
    let addresses = listener.handle();
    let hosts = AllowedHosts::new(&state.0.config.hosts, addresses.tailnet());
    let app = native::app(state.clone(), hosts);
    if let Some(online) = online {
        let _ = online.send(Online { state, addresses });
    }
    serve_connections(listener, app, stop).await
}

async fn serve_on_address(state: AppState, stop: &StopSignal) -> Result<(), String> {
    let address = state.0.config.listen_address();
    logger::warn(
        "server",
        &format!(
            "`address` is {}, so the server listens only on {address} and not on the tailnet; list the host names clients use under `hosts`, or remove `address` to listen on loopback and the tailnet",
            state.0.config.address
        ),
    );
    let listener = TcpListener::bind(&address).await.map_err(|err| {
        format!(
            "Could not listen on {address}: {err}. Another program may be using that port; set a different `port` in the configuration file, or `address` if this machine does not own that address."
        )
    })?;
    logger::info("server", &format!("listening on http://{address}"));
    let hosts = AllowedHosts::new(&state.0.config.hosts, TailnetAddresses::default());
    serve_connections(listener, native::app(state, hosts), stop).await
}

async fn serve_connections<L>(listener: L, app: Router, stop: &StopSignal) -> Result<(), String>
where
    L: axum::serve::Listener,
    L::Io: AsyncRead + AsyncWrite + Unpin + Send + 'static,
    L::Addr: ConnectionAddr + std::fmt::Debug,
{
    let draining = stop.clone();
    let limits = Limits::default();
    descriptors::warn_if_too_low(&limits);
    let server = net::serve(listener, app, ConnectionLimits::new(limits), async move { draining.raised().await });
    match shutdown::run_until_stopped(server, stop, shutdown::GRACE).await {
        Some(result) => result.map_err(|err| format!("The server stopped: {err}. Start it again with `flaccy-server serve`; if this repeats, check the log in the data folder.")),
        None => {
            logger::warn(
                "server",
                &format!("open requests were still running {} seconds after the stop request; closing them", shutdown::GRACE.as_secs()),
            );
            Ok(())
        }
    }
}
