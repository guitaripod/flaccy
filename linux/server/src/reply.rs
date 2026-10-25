//! The Subsonic response envelope, as JSON or XML.

use axum::body::Body;
use axum::http::{header, HeaderValue, StatusCode};
use axum::response::Response;
use serde_json::{json, Map, Value};

use crate::error::ApiError;
use crate::request::Params;
use crate::xml;

/// The Subsonic REST API version this server speaks.
pub const API_VERSION: &str = "1.16.1";
/// What `ping` reports as the server type.
pub const SERVER_TYPE: &str = "flaccy-server";
const NAMESPACE: &str = "http://subsonic.org/restapi";

/// How the client asked for the answer.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Format {
    Json,
    Xml,
}

/// `f=json` asks for JSON; anything else, including no `f`, gets XML, which is
/// all that older apps speak.
pub fn format_of(params: &Params) -> Format {
    match params.get("f") {
        Some("json") => Format::Json,
        _ => Format::Xml,
    }
}

fn envelope(status: &str, fields: Map<String, Value>) -> Map<String, Value> {
    let mut body = Map::new();
    body.insert("status".into(), json!(status));
    body.insert("version".into(), json!(API_VERSION));
    body.insert("type".into(), json!(SERVER_TYPE));
    body.insert("serverVersion".into(), json!(env!("CARGO_PKG_VERSION")));
    body.insert("openSubsonic".into(), json!(true));
    body.extend(fields);
    body
}

/// An `ok` envelope carrying `fields`.
pub fn success(fields: Map<String, Value>) -> Map<String, Value> {
    envelope("ok", fields)
}

/// A `failed` envelope carrying `error`.
pub fn failure(error: &ApiError) -> Map<String, Value> {
    let mut fields = Map::new();
    fields.insert(
        "error".into(),
        json!({"code": error.code, "message": error.message}),
    );
    envelope("failed", fields)
}

/// Writes `body` as the HTTP answer. Subsonic reports errors inside a 200.
pub fn render(format: Format, body: Map<String, Value>) -> Response {
    let (content_type, text) = match format {
        Format::Json => (
            "application/json; charset=utf-8",
            Value::Object(Map::from_iter([("subsonic-response".to_string(), Value::Object(body))])).to_string(),
        ),
        Format::Xml => (
            "application/xml; charset=utf-8",
            xml::document("subsonic-response", NAMESPACE, &body),
        ),
    };
    let mut response = Response::new(Body::from(text));
    *response.status_mut() = StatusCode::OK;
    response
        .headers_mut()
        .insert(header::CONTENT_TYPE, HeaderValue::from_static(content_type));
    response
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn xml_is_the_default_and_json_must_be_asked_for() {
        assert_eq!(format_of(&Params::default()), Format::Xml);
        assert_eq!(format_of(&Params::from_pairs(&[("f", "xml")])), Format::Xml);
        assert_eq!(format_of(&Params::from_pairs(&[("f", "json")])), Format::Json);
    }

    #[test]
    fn a_failure_names_its_code_and_message() {
        let body = failure(&ApiError::new(40, "nope"));
        assert_eq!(body["status"], "failed");
        assert_eq!(body["error"]["code"], 40);
    }
}
