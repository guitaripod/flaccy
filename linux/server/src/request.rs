//! The parameters of one REST call, from the query string and a form body.

/// Every `name=value` pair a request carried, in order, repeats included.
#[derive(Clone, Debug, Default)]
pub struct Params {
    pairs: Vec<(String, String)>,
}

impl Params {
    /// Reads the query string and, for a form post, the body. A body or query
    /// that is not valid form encoding contributes nothing.
    pub fn parse(query: Option<&str>, body: &[u8]) -> Self {
        let mut pairs = Vec::new();
        if let Some(query) = query {
            pairs.extend(decode(query));
        }
        if !body.is_empty() {
            if let Ok(text) = std::str::from_utf8(body) {
                pairs.extend(decode(text));
            }
        }
        Self { pairs }
    }

    /// Params built from literal pairs.
    pub fn from_pairs(pairs: &[(&str, &str)]) -> Self {
        Self {
            pairs: pairs
                .iter()
                .map(|(name, value)| (name.to_string(), value.to_string()))
                .collect(),
        }
    }

    /// The first value of `name`.
    pub fn get(&self, name: &str) -> Option<&str> {
        self.pairs
            .iter()
            .find(|(key, _)| key == name)
            .map(|(_, value)| value.as_str())
    }

    /// Every value of `name`, for parameters such as `songId` that repeat.
    pub fn all(&self, name: &str) -> Vec<&str> {
        self.pairs
            .iter()
            .filter(|(key, _)| key == name)
            .map(|(_, value)| value.as_str())
            .collect()
    }

    /// The first value of `name` as an integer, `None` when absent or not a number.
    pub fn int(&self, name: &str) -> Option<i64> {
        self.get(name).and_then(|value| value.trim().parse().ok())
    }

    /// The first value of `name` as a flag.
    pub fn flag(&self, name: &str) -> Option<bool> {
        match self.get(name)?.trim().to_ascii_lowercase().as_str() {
            "true" | "1" | "yes" => Some(true),
            "false" | "0" | "no" => Some(false),
            _ => None,
        }
    }
}

fn decode(text: &str) -> Vec<(String, String)> {
    serde_urlencoded::from_str::<Vec<(String, String)>>(text).unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn query_and_form_body_merge_and_repeats_are_kept() {
        let params = Params::parse(Some("u=a&id=s1&id=s2"), b"p=pa%20ss&songId=s3");
        assert_eq!(params.get("u"), Some("a"));
        assert_eq!(params.all("id"), vec!["s1", "s2"]);
        assert_eq!(params.get("p"), Some("pa ss"));
        assert_eq!(params.get("missing"), None);
    }

    #[test]
    fn numbers_and_flags_parse_leniently() {
        let params = Params::parse(Some("size=12&offset=x&submission=false&a=1"), b"");
        assert_eq!(params.int("size"), Some(12));
        assert_eq!(params.int("offset"), None);
        assert_eq!(params.flag("submission"), Some(false));
        assert_eq!(params.flag("a"), Some(true));
        assert_eq!(params.flag("zzz"), None);
    }
}
