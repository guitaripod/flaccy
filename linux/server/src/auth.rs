//! Who is calling: an API key, a Subsonic token or a plain password.

use crate::credentials::Credentials;
use crate::error::ApiError;
use crate::ids;
use crate::request::Params;

const NO_ACCOUNT: &str = "This server has no account yet, so no login can succeed. On the machine running flaccy-server, run `flaccy-server password set` (or `flaccy-server key add <name>`), then try again.";

/// How a request proved who it is.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Login {
    Key(String),
    Account,
}

/// Checks the credentials a request carries against the account.
///
/// Errors follow the Subsonic and OpenSubsonic codes: 10 when nothing to log
/// in with was sent, 40 for a wrong user, password or token, 43 when an API key
/// arrives together with a user name, and 44 for an unknown or revoked key.
pub fn authenticate(params: &Params, credentials: Option<&Credentials>) -> Result<Login, ApiError> {
    let key = params.get("apiKey");
    let user = params.get("u");
    if key.is_some() && user.is_some() {
        return Err(ApiError::new(
            43,
            "The request carries both apiKey and u. Send an API key alone, or a user name with a token (t and s) or password (p), not both.",
        ));
    }
    if let Some(key) = key {
        return credentials
            .and_then(|credentials| credentials.key_name(key))
            .map(|name| Login::Key(name.to_string()))
            .ok_or_else(|| {
                ApiError::new(
                    44,
                    "The API key is not known to this server; it may have been revoked. Make a new one with `flaccy-server key add <name>` and enter it in your client.",
                )
            });
    }
    let Some(user) = user else {
        return Err(ApiError::new(
            10,
            "The request carries no login. Send apiKey, or u with t and s (token) or p (password); check the username and password or API key saved in your client.",
        ));
    };
    let credentials = credentials.ok_or_else(|| ApiError::new(40, NO_ACCOUNT))?;
    let accepted = credentials.is_user(user) && password_accepted(params, credentials)?;
    if accepted {
        Ok(Login::Account)
    } else {
        Err(ApiError::new(
            40,
            "The user name or password is wrong. Check what your client has saved; the password can be changed with `flaccy-server password set`.",
        ))
    }
}

fn password_accepted(params: &Params, credentials: &Credentials) -> Result<bool, ApiError> {
    if let (Some(token), Some(salt)) = (params.get("t"), params.get("s")) {
        return Ok(credentials.token_matches(token, salt));
    }
    if let Some(password) = params.get("p") {
        return Ok(match password.strip_prefix("enc:") {
            Some(encoded) => ids::unhex(encoded)
                .and_then(|bytes| String::from_utf8(bytes).ok())
                .is_some_and(|decoded| credentials.password_matches(&decoded)),
            None => credentials.password_matches(password),
        });
    }
    Err(ApiError::new(
        10,
        "The request names a user but no password. Send t and s (token and salt) or p (password) with u.",
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use md5::{Digest, Md5};

    fn account() -> Credentials {
        let mut credentials = Credentials {
            username: "tester".to_string(),
            password: "sesame-seed".to_string(),
            keys: Vec::new(),
        };
        credentials.add_key("phone", "now").unwrap();
        credentials
    }

    fn code(result: Result<Login, ApiError>) -> i64 {
        result.unwrap_err().code
    }

    #[test]
    fn nothing_sent_is_code_10() {
        assert_eq!(code(authenticate(&Params::default(), Some(&account()))), 10);
        assert_eq!(code(authenticate(&Params::from_pairs(&[("u", "tester")]), Some(&account()))), 10);
    }

    #[test]
    fn a_wrong_user_password_or_token_is_code_40() {
        let account = account();
        let wrong_user = Params::from_pairs(&[("u", "nobody"), ("p", "sesame-seed")]);
        let wrong_password = Params::from_pairs(&[("u", "tester"), ("p", "nope")]);
        let wrong_token = Params::from_pairs(&[("u", "tester"), ("t", "00"), ("s", "salt")]);
        assert_eq!(code(authenticate(&wrong_user, Some(&account))), 40);
        assert_eq!(code(authenticate(&wrong_password, Some(&account))), 40);
        assert_eq!(code(authenticate(&wrong_token, Some(&account))), 40);
        assert_eq!(code(authenticate(&wrong_password, None)), 40);
    }

    #[test]
    fn plain_encoded_and_token_logins_all_work() {
        let account = account();
        let plain = Params::from_pairs(&[("u", "tester"), ("p", "sesame-seed")]);
        let encoded = format!("enc:{}", ids::hex(b"sesame-seed"));
        let hex = Params::from_pairs(&[("u", "Tester"), ("p", &encoded)]);
        let mut hasher = Md5::new();
        hasher.update(b"sesame-seedabc123");
        let token = ids::hex(&hasher.finalize());
        let tokened = Params::from_pairs(&[("u", "tester"), ("t", &token), ("s", "abc123")]);
        for params in [plain, hex, tokened] {
            assert_eq!(authenticate(&params, Some(&account)), Ok(Login::Account));
        }
    }

    #[test]
    fn an_api_key_alone_logs_in_and_an_unknown_one_is_code_44() {
        let mut account = account();
        let key = account.add_key("laptop", "now").unwrap();
        let good = Params::from_pairs(&[("apiKey", &key)]);
        assert_eq!(authenticate(&good, Some(&account)), Ok(Login::Key("laptop".to_string())));
        let bad = Params::from_pairs(&[("apiKey", "deadbeef")]);
        assert_eq!(code(authenticate(&bad, Some(&account))), 44);
    }

    #[test]
    fn an_api_key_together_with_a_user_is_code_43() {
        let both = Params::from_pairs(&[("apiKey", "x"), ("u", "tester")]);
        assert_eq!(code(authenticate(&both, Some(&account()))), 43);
    }
}
