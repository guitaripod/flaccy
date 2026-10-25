//! Requests to one OpenSubsonic server, and what their failures mean to a
//! person. A failure carries the cause but never the request URL: that URL
//! holds the credentials, so every message is built from the host, the failure
//! kind and the HTTP library's own message, passed through `redact`.

use super::redact::redact;
use super::servers::Server;
use flaccy_shared::remote::server_address;
use flaccy_shared::remote::subsonic_request::{self, Credentials};
use flaccy_shared::remote::subsonic_response::{Child, Envelope, Root, SubsonicFailure};
use md5::{Digest, Md5};
use std::io::Read;
use std::ops::Range;
use std::time::Duration;

const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
const READ_TIMEOUT: Duration = Duration::from_secs(30);
const MAX_BODY_BYTES: u64 = 64 * 1024 * 1024;
const SALT_LENGTH: usize = 16;

/// Why a request to a server failed, in the terms a person can act on.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RemoteError {
    BadAddress,
    Unreachable { host: String, cause: String },
    Tls { host: String, cause: String },
    WrongCredentials { host: String, api_key: bool },
    NotOpenSubsonic { host: String },
    Rejected { host: String, cause: String },
    Incomplete { host: String, cause: String },
    RangeRefused { host: String },
}

impl RemoteError {
    /// The full sentence for a toast or a status row: what failed, the cause and
    /// the next step.
    pub fn message(&self) -> String {
        match self {
            Self::BadAddress => "The server address can't be used. Type it like https://music.example.com or http://192.168.1.5:4533 and try again.".to_string(),
            Self::Unreachable { host, cause } => format!(
                "Can't reach {host}: {cause}. Check the address and that the server is running, or connect to the network or Tailscale, then try again."
            ),
            Self::Tls { host, cause } => format!(
                "Can't make a secure connection to {host}: {cause}. Check the server's certificate, or use an http:// address on a network you trust, then try again."
            ),
            Self::WrongCredentials { host, api_key } => {
                let secret = if *api_key { "API key" } else { "username or password" };
                format!("{host} rejected the {secret}. Check it in Preferences, then try again.")
            }
            Self::NotOpenSubsonic { host } => format!(
                "{host} answered, but it isn't an OpenSubsonic server. Check the address, including any path such as /navidrome, and try again."
            ),
            Self::Rejected { host, cause } => format!(
                "{host} refused the request: {cause}. Check the server's log, then try again."
            ),
            Self::Incomplete { host, cause } => format!(
                "{host} stopped answering part way: {cause}. Try again once the connection is steady."
            ),
            Self::RangeRefused { host } => format!(
                "{host} no longer has the bytes asked for, so the song changed on the server. Refresh the server in Preferences and play it again."
            ),
        }
    }

    /// Whether the server could not be reached at all, as opposed to answering
    /// with a refusal.
    pub fn is_connection_failure(&self) -> bool {
        matches!(
            self,
            Self::Unreachable { .. } | Self::Tls { .. }
        )
    }
}

impl std::fmt::Display for RemoteError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.message())
    }
}

/// What a server says about itself.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ServerInfo {
    pub server_type: String,
    pub server_version: String,
    pub extensions: Vec<String>,
}

impl ServerInfo {
    /// "navidrome 0.64.2", the way the Servers page shows a passed test.
    pub fn summary(&self) -> String {
        let version = self.server_version.split(' ').next().unwrap_or_default();
        format!("{} {}", self.server_type, version).trim().to_string()
    }
}

/// The part of a streamed answer the cache needs.
pub struct Streamed {
    pub status: u16,
    pub content_range: Option<(u64, u64, u64)>,
    pub content_length: Option<u64>,
    pub validator: Option<String>,
    pub reader: Box<dyn Read + Send>,
}

/// A signed connection to one server.
#[derive(Clone)]
pub struct Client {
    server_id: String,
    host: String,
    base: String,
    credentials: Credentials,
    agent: ureq::Agent,
}

impl Client {
    pub fn new(server: &Server) -> Result<Self, RemoteError> {
        let base = server_address::normalize(&server.address).ok_or(RemoteError::BadAddress)?;
        let host = base
            .split_once("://")
            .map(|(_, rest)| rest.split('/').next().unwrap_or(rest))
            .unwrap_or(&base)
            .to_string();
        let agent = ureq::AgentBuilder::new()
            .timeout_connect(CONNECT_TIMEOUT)
            .timeout_read(READ_TIMEOUT)
            .user_agent("flaccy")
            .build();
        Ok(Self {
            server_id: server.id.clone(),
            host,
            base,
            credentials: server.credentials(),
            agent,
        })
    }

    pub fn server_id(&self) -> &str {
        &self.server_id
    }

    /// The `host:port` the requests go to, safe to show and to log.
    pub fn host(&self) -> &str {
        &self.host
    }

    fn url(&self, method: &str, parameters: &[(&str, &str)]) -> String {
        let salt = new_salt();
        subsonic_request::url(
            &self.base,
            method,
            parameters,
            &self.credentials,
            &salt,
            &md5_hex,
        )
    }

    fn map_transport(&self, error: ureq::Error) -> RemoteError {
        let host = self.host.clone();
        match error {
            ureq::Error::Status(code, _) => match code {
                401 | 403 => RemoteError::WrongCredentials {
                    host,
                    api_key: matches!(self.credentials, Credentials::ApiKey(_)),
                },
                404 | 405 => RemoteError::NotOpenSubsonic { host },
                416 => RemoteError::RangeRefused { host },
                other => RemoteError::Rejected {
                    host,
                    cause: format!("HTTP status {other}"),
                },
            },
            ureq::Error::Transport(transport) => {
                let cause = redact(&format!(
                    "{}{}",
                    transport.kind(),
                    transport
                        .message()
                        .map(|message| format!(" ({message})"))
                        .unwrap_or_default()
                ));
                let lowered = redact(&transport.to_string()).to_lowercase();
                let secure = ["certificate", "tls", "handshake", "ssl"]
                    .iter()
                    .any(|word| lowered.contains(word));
                if secure {
                    RemoteError::Tls { host, cause }
                } else {
                    RemoteError::Unreachable { host, cause }
                }
            }
        }
    }

    /// Calls `method` and decodes the envelope, turning a failed status into the
    /// error its code names.
    pub fn call(&self, method: &str, parameters: &[(&str, &str)]) -> Result<Envelope, RemoteError> {
        let response = self
            .agent
            .get(&self.url(method, parameters))
            .call()
            .map_err(|error| self.map_transport(error))?;
        let mut body = String::new();
        response
            .into_reader()
            .take(MAX_BODY_BYTES)
            .read_to_string(&mut body)
            .map_err(|error| RemoteError::Incomplete {
                host: self.host.clone(),
                cause: redact(&error.to_string()),
            })?;
        let root = serde_json::from_str::<Root>(&body).map_err(|_| RemoteError::NotOpenSubsonic {
            host: self.host.clone(),
        })?;
        self.check(root.response)
    }

    fn check(&self, envelope: Envelope) -> Result<Envelope, RemoteError> {
        let host = self.host.clone();
        match envelope.failure() {
            None => Ok(envelope),
            Some(
                SubsonicFailure::WrongCredentials
                | SubsonicFailure::InvalidApiKey
                | SubsonicFailure::NotAuthorized,
            ) => Err(RemoteError::WrongCredentials {
                host,
                api_key: matches!(self.credentials, Credentials::ApiKey(_)),
            }),
            Some(SubsonicFailure::TokenAuthUnsupported | SubsonicFailure::AuthMechanismUnsupported) => {
                Err(RemoteError::Rejected {
                    host,
                    cause: "it doesn't accept this sign-in method; add an API key instead of a password"
                        .to_string(),
                })
            }
            Some(other) => Err(RemoteError::Rejected {
                host,
                cause: envelope
                    .error
                    .and_then(|error| error.message)
                    .unwrap_or_else(|| format!("{other:?}")),
            }),
        }
    }

    /// Tests the connection the way the Servers page does: a ping, then the
    /// list of OpenSubsonic extensions.
    pub fn test(&self) -> Result<ServerInfo, RemoteError> {
        let ping = self.call("ping", &[])?;
        if ping.open_subsonic != Some(true) {
            return Err(RemoteError::NotOpenSubsonic {
                host: self.host.clone(),
            });
        }
        let extensions = self
            .call("getOpenSubsonicExtensions", &[])
            .map(|envelope| {
                envelope
                    .open_subsonic_extensions
                    .unwrap_or_default()
                    .into_iter()
                    .filter_map(|extension| extension.name)
                    .collect()
            })
            .unwrap_or_default();
        Ok(ServerInfo {
            server_type: ping.server_type.unwrap_or_else(|| "OpenSubsonic".to_string()),
            server_version: ping.server_version.unwrap_or_default(),
            extensions,
        })
    }

    /// One page of every song, using `search3` with an empty query.
    pub fn search_songs(&self, offset: usize, count: usize) -> Result<Vec<Child>, RemoteError> {
        let envelope = self.call(
            "search3",
            &[
                ("query", ""),
                ("artistCount", "0"),
                ("albumCount", "0"),
                ("songCount", &count.to_string()),
                ("songOffset", &offset.to_string()),
            ],
        )?;
        Ok(envelope
            .search_result3
            .and_then(|result| result.song)
            .unwrap_or_default())
    }

    /// The ids of one page of albums, sorted by name.
    pub fn album_ids(&self, offset: usize, count: usize) -> Result<Vec<String>, RemoteError> {
        let envelope = self.call(
            "getAlbumList2",
            &[
                ("type", "alphabeticalByName"),
                ("size", &count.to_string()),
                ("offset", &offset.to_string()),
            ],
        )?;
        Ok(envelope
            .album_list2
            .and_then(|list| list.album)
            .unwrap_or_default()
            .into_iter()
            .map(|album| album.id)
            .collect())
    }

    /// The songs of one album.
    pub fn album_songs(&self, album_id: &str) -> Result<Vec<Child>, RemoteError> {
        let envelope = self.call("getAlbum", &[("id", album_id)])?;
        Ok(envelope
            .album
            .and_then(|album| album.song)
            .unwrap_or_default())
    }

    /// The bytes of a cover, scaled to `size` pixels on its longest side.
    pub fn cover_art(&self, id: &str, size: u32) -> Result<Vec<u8>, RemoteError> {
        let response = self
            .agent
            .get(&self.url("getCoverArt", &[("id", id), ("size", &size.to_string())]))
            .call()
            .map_err(|error| self.map_transport(error))?;
        let mut bytes = Vec::new();
        response
            .into_reader()
            .take(MAX_BODY_BYTES)
            .read_to_end(&mut bytes)
            .map_err(|error| RemoteError::Incomplete {
                host: self.host.clone(),
                cause: redact(&error.to_string()),
            })?;
        Ok(bytes)
    }

    /// Tells the server a song started (`submission` false) or was listened to
    /// (`submission` true), at `time_ms` since the epoch.
    pub fn scrobble(&self, song: &str, time_ms: i64, submission: bool) -> Result<(), RemoteError> {
        self.call(
            "scrobble",
            &[
                ("id", song),
                ("time", &time_ms.to_string()),
                ("submission", if submission { "true" } else { "false" }),
            ],
        )
        .map(|_| ())
    }

    /// Stars or unstars a song.
    pub fn set_starred(&self, song: &str, starred: bool) -> Result<(), RemoteError> {
        self.call(if starred { "star" } else { "unstar" }, &[("id", song)])
            .map(|_| ())
    }

    /// The song's original file, from the `download` method.
    pub fn download(&self, song: &str) -> Result<Vec<u8>, RemoteError> {
        let response = self
            .agent
            .get(&self.url("download", &[("id", song)]))
            .call()
            .map_err(|error| self.map_transport(error))?;
        let mut bytes = Vec::new();
        response
            .into_reader()
            .read_to_end(&mut bytes)
            .map_err(|error| RemoteError::Incomplete {
                host: self.host.clone(),
                cause: redact(&error.to_string()),
            })?;
        Ok(bytes)
    }

    /// Opens the song's untranscoded stream. `range` asks for those bytes only
    /// and `if_range` makes the server answer the whole file when its validator
    /// no longer matches.
    pub fn stream(
        &self,
        song: &str,
        range: Option<Range<u64>>,
        if_range: Option<&str>,
    ) -> Result<Streamed, RemoteError> {
        let mut request = self
            .agent
            .get(&self.url("stream", &[("id", song), ("format", "raw")]));
        if let Some(range) = range.filter(|range| range.end > range.start) {
            request = request.set("Range", &format!("bytes={}-{}", range.start, range.end - 1));
            if let Some(validator) = if_range {
                request = request.set("If-Range", validator);
            }
        }
        let response = request.call().map_err(|error| self.map_transport(error))?;
        let status = response.status();
        let content_length = response
            .header("Content-Length")
            .and_then(|value| value.trim().parse::<u64>().ok());
        let content_range = response.header("Content-Range").and_then(parse_content_range);
        let validator = response
            .header("ETag")
            .filter(|tag| !tag.starts_with("W/"))
            .or_else(|| response.header("Last-Modified"))
            .map(str::to_string);
        Ok(Streamed {
            status,
            content_range,
            content_length,
            validator,
            reader: Box::new(response.into_reader()),
        })
    }
}

/// The first byte, last byte and total of a `bytes first-last/total` header.
fn parse_content_range(value: &str) -> Option<(u64, u64, u64)> {
    let (span, total) = value.trim().strip_prefix("bytes ")?.split_once('/')?;
    let (first, last) = span.split_once('-')?;
    Some((
        first.trim().parse().ok()?,
        last.trim().parse().ok()?,
        total.trim().parse().ok()?,
    ))
}

fn new_salt() -> String {
    let mut salt = String::with_capacity(SALT_LENGTH);
    while salt.len() < SALT_LENGTH {
        salt.push_str(&format!("{:016x}", rand::random::<u64>()));
    }
    salt.truncate(SALT_LENGTH);
    salt
}

fn md5_hex(input: &str) -> String {
    format!("{:x}", Md5::digest(input.as_bytes()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::remote::testing::FixtureServer;

    #[test]
    fn content_range_headers_are_read_into_their_three_numbers() {
        assert_eq!(parse_content_range("bytes 10-19/100"), Some((10, 19, 100)));
        assert_eq!(parse_content_range("bytes */100"), None);
        assert_eq!(parse_content_range("items 1-2/3"), None);
    }

    #[test]
    fn the_salt_is_sixteen_hex_characters_and_never_repeats() {
        let first = new_salt();
        assert_eq!(first.len(), 16);
        assert!(first.bytes().all(|byte| byte.is_ascii_hexdigit()));
        assert_ne!(first, new_salt());
    }

    #[test]
    fn the_token_is_the_md5_of_the_password_and_the_salt() {
        assert_eq!(md5_hex("abc"), "900150983cd24fb0d6963f7d28e17f72");
    }

    #[test]
    fn a_password_request_carries_a_token_and_not_the_password() {
        let server = Server::new("Home", "http://127.0.0.1:1", "ana", "hunter2", false);
        let client = Client::new(&server).unwrap();
        let url = client.url("ping", &[]);
        assert!(!url.contains("hunter2"));
        assert!(url.contains("&t="));
        assert!(url.contains("&s="));
    }

    #[test]
    fn an_unusable_address_is_named_before_any_request() {
        let server = Server::new("Home", "ftp://nope", "ana", "pw", false);
        assert_eq!(Client::new(&server).err(), Some(RemoteError::BadAddress));
    }

    #[test]
    fn a_closed_port_reads_as_unreachable_without_the_credentials() {
        let server = Server::new("Home", "http://127.0.0.1:1", "ana", "hunter2", false);
        let error = Client::new(&server).unwrap().test().unwrap_err();
        assert!(matches!(error, RemoteError::Unreachable { .. }));
        let message = error.message();
        assert!(!message.contains("hunter2"));
        assert!(!message.contains("ana&"));
        assert!(message.contains("127.0.0.1:1"));
    }

    #[test]
    fn a_secure_address_on_a_plain_port_reads_as_a_tls_failure() {
        let fixture = FixtureServer::start();
        let secure = fixture.address().replace("http://", "https://");
        let server = Server::new("Fixture", &secure, "ana", "hunter2", false);
        let error = Client::new(&server).unwrap().test().unwrap_err();
        assert!(matches!(error, RemoteError::Tls { .. }), "{error:?}");
        assert!(error.message().contains("secure connection"));
        assert!(!error.message().contains("hunter2"));
    }

    #[test]
    fn a_passing_test_reports_the_server_type_and_version() {
        let fixture = FixtureServer::start();
        let server = Server::new("Fixture", &fixture.address(), "ana", "pw", false);
        let info = Client::new(&server).unwrap().test().unwrap();
        assert_eq!(info.server_type, "navidrome");
        assert_eq!(info.summary(), "navidrome 0.64.2");
        assert!(info.extensions.contains(&"songLyrics".to_string()));
    }

    #[test]
    fn a_page_that_is_not_json_is_not_opensubsonic() {
        let fixture = FixtureServer::start();
        let server = Server::new("Fixture", &format!("{}/not-subsonic", fixture.address()), "ana", "pw", false);
        let error = Client::new(&server).unwrap().test().unwrap_err();
        assert!(matches!(error, RemoteError::NotOpenSubsonic { .. }));
    }

    #[test]
    fn a_rejected_login_names_the_credentials() {
        let fixture = FixtureServer::start();
        fixture.reject_logins();
        let server = Server::new("Fixture", &fixture.address(), "ana", "bad", false);
        let error = Client::new(&server).unwrap().test().unwrap_err();
        assert!(matches!(error, RemoteError::WrongCredentials { api_key: false, .. }));
        assert!(error.message().contains("username or password"));
    }

    #[test]
    fn a_server_that_is_not_opensubsonic_says_so() {
        let fixture = FixtureServer::start();
        fixture.answer_plain_subsonic();
        let server = Server::new("Fixture", &fixture.address(), "ana", "pw", false);
        let error = Client::new(&server).unwrap().test().unwrap_err();
        assert!(matches!(error, RemoteError::NotOpenSubsonic { .. }));
    }
}
