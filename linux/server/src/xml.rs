//! Turns a JSON value into the XML a Subsonic client reads.
//!
//! The rules are generic so every answer is built once, as JSON. Scalar fields
//! become attributes, an object becomes a child element named by its key, an
//! array repeats the element once per item, and booleans are `true` and
//! `false`. A field called `value` is the element's text, which is how a lyric
//! line carries its words.

use serde_json::{Map, Value};

const TEXT_KEY: &str = "value";

/// The document for `body`, rooted at an element called `name` with `namespace`.
pub fn document(name: &str, namespace: &str, body: &Map<String, Value>) -> String {
    let mut out = String::from("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
    write_element(&mut out, name, body, Some(namespace));
    out
}

fn write_element(out: &mut String, name: &str, object: &Map<String, Value>, namespace: Option<&str>) {
    out.push('<');
    out.push_str(name);
    if let Some(namespace) = namespace {
        push_attribute(out, "xmlns", namespace);
    }
    for (key, value) in object {
        if key == TEXT_KEY {
            continue;
        }
        if let Some(text) = scalar_text(value) {
            push_attribute(out, key, &text);
        }
    }
    let text = object.get(TEXT_KEY).and_then(scalar_text);
    let children: Vec<(&String, &Value)> = object
        .iter()
        .filter(|(key, value)| key.as_str() != TEXT_KEY && matches!(value, Value::Object(_) | Value::Array(_)))
        .collect();
    if text.is_none() && children.is_empty() {
        out.push_str("/>");
        return;
    }
    out.push('>');
    if let Some(text) = text {
        out.push_str(&escape(&text));
    }
    for (key, value) in children {
        write_child(out, key, value);
    }
    out.push_str("</");
    out.push_str(name);
    out.push('>');
}

fn write_child(out: &mut String, name: &str, value: &Value) {
    match value {
        Value::Object(object) => write_element(out, name, object, None),
        Value::Array(items) => {
            for item in items {
                match item {
                    Value::Object(object) => write_element(out, name, object, None),
                    Value::Array(_) => write_child(out, name, item),
                    other => {
                        if let Some(text) = scalar_text(other) {
                            out.push('<');
                            out.push_str(name);
                            out.push('>');
                            out.push_str(&escape(&text));
                            out.push_str("</");
                            out.push_str(name);
                            out.push('>');
                        }
                    }
                }
            }
        }
        _ => {}
    }
}

fn scalar_text(value: &Value) -> Option<String> {
    match value {
        Value::String(text) => Some(text.clone()),
        Value::Number(number) => Some(number.to_string()),
        Value::Bool(flag) => Some(flag.to_string()),
        Value::Null | Value::Object(_) | Value::Array(_) => None,
    }
}

fn push_attribute(out: &mut String, name: &str, value: &str) {
    out.push(' ');
    out.push_str(name);
    out.push_str("=\"");
    out.push_str(&escape(value));
    out.push('"');
}

fn escape(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for character in text.chars() {
        match character {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&apos;"),
            control if (control as u32) < 0x20 && !matches!(control, '\t' | '\n' | '\r') => {}
            other => out.push(other),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn render(value: Value) -> String {
        document("root", "urn:x", value.as_object().unwrap())
    }

    #[test]
    fn scalars_are_attributes_and_objects_are_children() {
        let xml = render(json!({"status": "ok", "ready": true, "count": 3, "gone": null, "album": {"id": "a", "year": 1999}}));
        assert!(xml.contains("<root xmlns=\"urn:x\""));
        assert!(xml.contains("status=\"ok\"") && xml.contains("ready=\"true\"") && xml.contains("count=\"3\""));
        assert!(!xml.contains("gone"));
        assert!(xml.contains("<album id=\"a\" year=\"1999\"/>"));
    }

    #[test]
    fn arrays_repeat_the_element_once_per_item() {
        let xml = render(json!({"album": {"song": [{"id": "s1"}, {"id": "s2"}], "versions": [1, 2]}}));
        assert_eq!(xml.matches("<song ").count(), 2);
        assert!(xml.contains("<versions>1</versions><versions>2</versions>"));
    }

    #[test]
    fn a_value_field_is_the_element_text_and_text_is_escaped() {
        let xml = render(json!({"line": [{"start": 10, "value": "Tom & \"Jerry\" <3"}]}));
        assert!(xml.contains("<line start=\"10\">Tom &amp; &quot;Jerry&quot; &lt;3</line>"));
    }

    #[test]
    fn control_characters_never_reach_the_document() {
        assert!(!render(json!({"a": "x\u{1}y"})).contains('\u{1}'));
    }
}
