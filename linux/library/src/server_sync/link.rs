use crate::remote::{decode_segment, encode_segment};
use flaccy_shared::remote::server_address::normalize;
use std::fmt;

const SCHEME_PREFIX: &str = "flaccy://server";

/// Why a pairing link could not be read.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LinkError {
    /// The text is not a `flaccy://server` link.
    NotAServerLink,
    /// The link carries no usable `url`.
    MissingUrl,
}

impl fmt::Display for LinkError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            LinkError::NotAServerLink => write!(formatter, "This is not a Flaccy Server link. Open the link the server printed, or paste it whole."),
            LinkError::MissingUrl => write!(formatter, "The link has no server address. Ask the server for a new link."),
        }
    }
}

impl std::error::Error for LinkError {}

/// A parsed `flaccy://server?url=&enroll=&name=&pin=&alt=` pairing link.
#[derive(Clone, PartialEq, Eq)]
pub struct ServerLink {
    /// The server's base URL, normalized.
    pub url: String,
    /// The single-use enrollment code, if the link carries one.
    pub enroll: Option<String>,
    /// The name the server offered for itself.
    pub name: Option<String>,
    /// The pin of the key every `https` address in the link answers with.
    pub pin: Option<String>,
    /// The address to try when `url` cannot be reached, normalized.
    pub alternate: Option<String>,
}

impl fmt::Debug for ServerLink {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("ServerLink")
            .field("url", &self.url)
            .field("enroll", &self.enroll.as_ref().map(|_| "***"))
            .field("name", &self.name)
            .field("pin", &self.pin)
            .field("alternate", &self.alternate)
            .finish()
    }
}

impl ServerLink {
    /// A link to `url` carrying an enrollment code.
    pub fn new(url: &str, enroll: Option<&str>, name: Option<&str>) -> Self {
        ServerLink {
            url: url.to_owned(),
            enroll: enroll.map(str::to_owned),
            name: name.map(str::to_owned),
            pin: None,
            alternate: None,
        }
    }

    /// The same link with the pin and the fallback address a local network server adds.
    pub fn reaching(mut self, pin: Option<&str>, alternate: Option<&str>) -> Self {
        self.pin = pin.map(str::to_owned);
        self.alternate = alternate.map(str::to_owned);
        self
    }

    /// The addresses to try, in order: `url`, then the fallback.
    pub fn candidates(&self) -> Vec<String> {
        std::iter::once(self.url.clone()).chain(self.alternate.clone()).collect()
    }

    /// Reads a pairing link; the old `key=` form parses too, with no enrollment code.
    pub fn parse(text: &str) -> Result<Self, LinkError> {
        let rest = text
            .trim()
            .strip_prefix(SCHEME_PREFIX)
            .ok_or(LinkError::NotAServerLink)?;
        let query = rest.strip_prefix('?').ok_or(LinkError::MissingUrl)?;
        let mut url = None;
        let mut enroll = None;
        let mut name = None;
        let mut pin = None;
        let mut alternate = None;
        for pair in query.split('&') {
            let (key, value) = pair.split_once('=').unwrap_or((pair, ""));
            let decoded = decode_segment(value).filter(|text| !text.is_empty());
            match key {
                "url" => url = decoded,
                "enroll" => enroll = decoded,
                "name" => name = decoded,
                "pin" => pin = decoded,
                "alt" => alternate = decoded.and_then(|raw| normalize(&raw)),
                _ => {}
            }
        }
        let url = url
            .and_then(|raw| normalize(&raw))
            .ok_or(LinkError::MissingUrl)?;
        Ok(ServerLink { url, enroll, name, pin, alternate })
    }
}

impl fmt::Display for ServerLink {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            formatter,
            "{SCHEME_PREFIX}?url={}",
            encode_segment(&self.url)
        )?;
        if let Some(code) = &self.enroll {
            write!(formatter, "&enroll={}", encode_segment(code))?;
        }
        if let Some(name) = &self.name {
            write!(formatter, "&name={}", encode_segment(name))?;
        }
        if let Some(pin) = &self.pin {
            write!(formatter, "&pin={}", encode_segment(pin))?;
        }
        if let Some(alternate) = &self.alternate {
            write!(formatter, "&alt={}", encode_segment(alternate))?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_link_round_trips_with_its_code_and_name() {
        let link = ServerLink::new(
            "https://box.tail1234.ts.net",
            Some("ABC123"),
            Some("My Phone"),
        );
        let parsed = ServerLink::parse(&link.to_string()).unwrap();
        assert_eq!(parsed, link);
    }

    #[test]
    fn a_local_network_link_carries_its_pin_and_fallback() {
        let parsed = ServerLink::parse(
            "flaccy://server?url=https%3A%2F%2Farch.local%3A4545&enroll=ABC&name=arch&pin=Ab-_9&alt=https%3A%2F%2F192.168.1.5%3A4545",
        )
        .unwrap();
        assert_eq!(parsed.url, "https://arch.local:4545");
        assert_eq!(parsed.pin.as_deref(), Some("Ab-_9"));
        assert_eq!(parsed.alternate.as_deref(), Some("https://192.168.1.5:4545"));
        assert_eq!(parsed.candidates(), vec!["https://arch.local:4545", "https://192.168.1.5:4545"]);
        assert_eq!(ServerLink::parse(&parsed.to_string()).unwrap(), parsed);
    }

    #[test]
    fn the_old_key_form_parses_without_a_code() {
        let parsed =
            ServerLink::parse("flaccy://server?url=http%3A%2F%2Fhost%3A4533%2F&key=abc&name=Home")
                .unwrap();
        assert_eq!(parsed.url, "http://host:4533");
        assert_eq!(parsed.enroll, None);
        assert_eq!(parsed.name.as_deref(), Some("Home"));
    }

    #[test]
    fn other_text_is_refused() {
        assert_eq!(
            ServerLink::parse("https://example.com"),
            Err(LinkError::NotAServerLink)
        );
        assert_eq!(
            ServerLink::parse("flaccy://server?name=x"),
            Err(LinkError::MissingUrl)
        );
    }

    #[test]
    fn debug_output_hides_the_code() {
        let link = ServerLink::new("http://h:1", Some("SECRETCODE"), None);
        assert!(!format!("{link:?}").contains("SECRETCODE"));
    }
}
