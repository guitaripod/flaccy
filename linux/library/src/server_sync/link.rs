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
    /// The addresses to try, in order, when `url` cannot be reached, normalized.
    pub alternates: Vec<String>,
}

impl fmt::Debug for ServerLink {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("ServerLink")
            .field("url", &self.url)
            .field("enroll", &self.enroll.as_ref().map(|_| "***"))
            .field("name", &self.name)
            .field("pin", &self.pin)
            .field("alternates", &self.alternates)
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
            alternates: Vec::new(),
        }
    }

    /// The same link with the pin and the fallback addresses a local network server adds.
    pub fn reaching(mut self, pin: Option<&str>, alternates: &[&str]) -> Self {
        self.pin = pin.map(str::to_owned);
        self.alternates = alternates.iter().map(|url| (*url).to_owned()).collect();
        self
    }

    /// The addresses to try, in order: `url`, then the fallbacks.
    pub fn candidates(&self) -> Vec<String> {
        std::iter::once(self.url.clone()).chain(self.alternates.iter().cloned()).collect()
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
        let mut alternates = Vec::new();
        for pair in query.split('&') {
            let (key, value) = pair.split_once('=').unwrap_or((pair, ""));
            let decoded = decode_segment(value).map(|text| text.trim().to_owned()).filter(|text| !text.is_empty());
            match key {
                "url" => keep_first(&mut url, decoded),
                "enroll" => keep_first(&mut enroll, decoded),
                "name" => keep_first(&mut name, decoded),
                "pin" => keep_first(&mut pin, decoded),
                "alt" => alternates.extend(decoded.and_then(|raw| normalize(&raw))),
                _ => {}
            }
        }
        let url = url
            .flatten()
            .and_then(|raw| normalize(&raw))
            .ok_or(LinkError::MissingUrl)?;
        Ok(ServerLink { url, enroll: enroll.flatten(), name: name.flatten(), pin: pin.flatten(), alternates })
    }
}

/// Keeps the first value a link gives for a key, empty or not, and ignores repeats, as the iPhone and Mac read links.
fn keep_first(slot: &mut Option<Option<String>>, value: Option<String>) {
    if slot.is_none() {
        *slot = Some(value);
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
        for alternate in &self.alternates {
            write!(formatter, "&alt={}", encode_segment(alternate))?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_first_value_of_a_repeated_key_wins_as_on_the_iphone() {
        let link = ServerLink::parse(
            "flaccy://server?url=https%3A%2F%2Fa.local%3A4545&url=https%3A%2F%2Fb.local%3A4545&enroll=ABC&enroll=XYZ&pin=one&pin=two",
        )
        .unwrap();
        assert_eq!(link.url, "https://a.local:4545");
        assert_eq!(link.enroll.as_deref(), Some("ABC"));
        assert_eq!(link.pin.as_deref(), Some("one"));
        assert_eq!(
            ServerLink::parse("flaccy://server?url=&url=https%3A%2F%2Farch.local%3A4545&enroll=ABC"),
            Err(LinkError::MissingUrl)
        );
    }

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
            "flaccy://server?url=http%3A%2F%2F100.64.0.1%3A4545&enroll=ABC&name=arch&pin=Ab-_9&alt=https%3A%2F%2Farch.local%3A4545&alt=https%3A%2F%2F192.168.1.5%3A4545",
        )
        .unwrap();
        assert_eq!(parsed.url, "http://100.64.0.1:4545");
        assert_eq!(parsed.pin.as_deref(), Some("Ab-_9"));
        assert_eq!(parsed.alternates, vec!["https://arch.local:4545", "https://192.168.1.5:4545"]);
        assert_eq!(
            parsed.candidates(),
            vec!["http://100.64.0.1:4545", "https://arch.local:4545", "https://192.168.1.5:4545"]
        );
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
