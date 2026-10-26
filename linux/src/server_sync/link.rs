use super::{address, copy};
use flaccy_library::remote::decode_segment;
use flaccy_library::server_sync::ServerLink;

const SCHEME_PREFIX: &str = "flaccy://server";

/// What a `flaccy://server` link asks the app to do.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Incoming {
    /// A Flaccy Server pairing link: open Add Flaccy Server with it filled in.
    FlaccyServer(ServerLink),
    /// An OpenSubsonic link with an API key: open Add Server with it filled in.
    Subsonic {
        /// The server's address.
        url: String,
        /// The API key the link carries.
        key: String,
        /// The name the link suggests.
        name: Option<String>,
    },
}

/// Reads a command line argument or a pasted link; `None` when it is not a server link.
pub fn classify(text: &str) -> Option<Incoming> {
    let trimmed = text.trim();
    if !trimmed.starts_with(SCHEME_PREFIX) {
        return None;
    }
    let link = ServerLink::parse(trimmed).ok()?;
    if link.enroll.is_some() {
        return Some(Incoming::FlaccyServer(link));
    }
    let key = query_value(trimmed, "key")?;
    Some(Incoming::Subsonic {
        url: link.url,
        key,
        name: link.name,
    })
}

/// What the Add Flaccy Server form asks for once its fields are read.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Request {
    /// Redeem this pairing link.
    Connect(ServerLink),
    /// The pasted link belongs to an OpenSubsonic server: hand it to the regular sheet.
    OtherServer(Incoming),
    /// An address with no code yet: find out what answers there.
    Probe(String),
}

/// Reads the form: a pasted link wins; otherwise the address and the code. The error is the sentence to show under the fields.
pub fn resolve_form(
    link_text: &str,
    address_text: &str,
    code_text: &str,
    offered_name: Option<&str>,
) -> Result<Request, &'static str> {
    if !link_text.trim().is_empty() {
        return match classify(link_text) {
            Some(Incoming::FlaccyServer(link)) => Ok(Request::Connect(link)),
            Some(other) => Ok(Request::OtherServer(other)),
            None => Err(copy::LINK_UNREADABLE),
        };
    }
    if address_text.trim().is_empty() {
        return Err(copy::NOTHING_TO_CONNECT);
    }
    let url = address::typed_address(address_text).ok_or(copy::ADDRESS_UNREADABLE)?;
    if address::canonical_code(code_text).is_empty() {
        return Ok(Request::Probe(url));
    }
    if !address::code_is_complete(code_text) {
        return Err(copy::CODE_INCOMPLETE);
    }
    let code = address::canonical_code(code_text);
    Ok(Request::Connect(ServerLink::new(&url, Some(&code), offered_name)))
}

fn query_value(link: &str, wanted: &str) -> Option<String> {
    let query = link.split_once('?')?.1;
    query.split('&').find_map(|pair| {
        let (key, value) = pair.split_once('=')?;
        (key == wanted)
            .then(|| decode_segment(value))
            .flatten()
            .filter(|decoded| !decoded.is_empty())
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_link_with_a_code_is_a_flaccy_server() {
        let incoming = classify("flaccy://server?url=http%3A%2F%2Farch%3A4545&enroll=ABCD&name=arch");
        let Some(Incoming::FlaccyServer(link)) = incoming else {
            panic!("expected a Flaccy Server link");
        };
        assert_eq!(link.url, "http://arch:4545");
        assert_eq!(link.enroll.as_deref(), Some("ABCD"));
        assert_eq!(link.name.as_deref(), Some("arch"));
    }

    #[test]
    fn a_link_with_a_key_is_an_opensubsonic_server() {
        let incoming = classify("flaccy://server?url=http%3A%2F%2Fhost%3A4533&key=s3cret&name=Home");
        assert_eq!(
            incoming,
            Some(Incoming::Subsonic {
                url: "http://host:4533".into(),
                key: "s3cret".into(),
                name: Some("Home".into()),
            })
        );
    }

    const FULL_CODE: &str = "0123-4567-89AB-CDEF-GHJK-MNPQ-RS";

    #[test]
    fn a_pasted_link_wins_over_the_typed_fields() {
        let request = resolve_form(
            "flaccy://server?url=http%3A%2F%2Farch%3A4545&enroll=ABCD",
            "other",
            FULL_CODE,
            None,
        );
        let Ok(Request::Connect(link)) = request else {
            panic!("expected a connect");
        };
        assert_eq!(link.url, "http://arch:4545");
    }

    #[test]
    fn typed_fields_make_a_link_with_the_canonical_code() {
        let request = resolve_form("", "arch", &FULL_CODE.to_lowercase(), Some("arch"));
        let Ok(Request::Connect(link)) = request else {
            panic!("expected a connect");
        };
        assert_eq!(link.url, "http://arch:4545");
        assert_eq!(link.enroll.as_deref(), Some("0123456789ABCDEFGHJKMNPQRS"));
        assert_eq!(link.name.as_deref(), Some("arch"));
    }

    #[test]
    fn an_address_alone_is_probed_and_a_short_code_is_refused() {
        assert_eq!(
            resolve_form("", "arch", "", None),
            Ok(Request::Probe("http://arch:4545".into()))
        );
        assert_eq!(
            resolve_form("", "arch", "ABCD", None),
            Err(copy::CODE_INCOMPLETE)
        );
    }

    #[test]
    fn empty_and_unreadable_fields_say_what_to_do() {
        assert_eq!(resolve_form("", "", "", None), Err(copy::NOTHING_TO_CONNECT));
        assert_eq!(resolve_form("nonsense", "", "", None), Err(copy::LINK_UNREADABLE));
        assert_eq!(resolve_form("", "ftp://x", FULL_CODE, None), Err(copy::ADDRESS_UNREADABLE));
    }

    #[test]
    fn a_key_link_goes_to_the_regular_sheet() {
        let request = resolve_form(
            "flaccy://server?url=http%3A%2F%2Fh%3A4533&key=k",
            "",
            "",
            None,
        );
        assert!(matches!(
            request,
            Ok(Request::OtherServer(Incoming::Subsonic { .. }))
        ));
    }

    #[test]
    fn anything_else_is_not_ours() {
        assert_eq!(classify("https://example.com"), None);
        assert_eq!(classify("flaccy://server?name=x"), None);
        assert_eq!(classify("flaccy://server?url=http%3A%2F%2Fhost"), None);
        assert_eq!(classify(""), None);
    }
}
