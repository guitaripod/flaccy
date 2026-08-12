use std::path::PathBuf;

/// Compile-time Last.fm credentials. They reach `option_env!` in `src/lastfm.rs`
/// from the environment (the release path, see `package.sh`) or, for local
/// builds, from a keys file kept outside the repository — so a working copy
/// never has to carry a secret and a plain `cargo build` still produces a
/// binary with the scrobbling surface intact.
///
/// Anything that isn't a real credential is blanked rather than passed through:
/// a placeholder compiles into a binary that *looks* authenticated and then
/// fails every signed call with "Invalid method signature", which is far worse
/// than an honest build with no keys at all.
const CREDENTIALS: [&str; 2] = ["FLACCY_LASTFM_KEY", "FLACCY_LASTFM_SECRET"];

fn main() {
    println!("cargo:rerun-if-env-changed=FLACCY_KEYS_FILE");
    let keys_file = keys_file();
    if let Some(path) = &keys_file {
        println!("cargo:rerun-if-changed={}", path.display());
    }
    for name in CREDENTIALS {
        println!("cargo:rerun-if-env-changed={name}");
        let value = std::env::var(name)
            .ok()
            .filter(|value| !value.trim().is_empty())
            .or_else(|| keys_file.as_deref().and_then(|path| read_key(path, name)));
        match value {
            Some(value) if looks_like_credential(&value) => {
                println!("cargo:rustc-env={name}={value}");
            }
            Some(_) => {
                println!(
                    "cargo:warning={name} is not a 32-character hex credential; \
                     building without Last.fm keys (scrobbling UI hidden)"
                );
                println!("cargo:rustc-env={name}=");
            }
            None => {}
        }
    }
}

/// `FLACCY_KEYS_FILE`, else `<config>/flaccy/build-keys.env`. Missing is fine —
/// that is just a build without Last.fm.
fn keys_file() -> Option<PathBuf> {
    if let Some(path) = std::env::var_os("FLACCY_KEYS_FILE") {
        let path = PathBuf::from(path);
        return path.is_file().then_some(path);
    }
    let config = std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
        .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".config")))?;
    let path = config.join("flaccy").join("build-keys.env");
    path.is_file().then_some(path)
}

fn read_key(path: &std::path::Path, name: &str) -> Option<String> {
    let contents = std::fs::read_to_string(path).ok()?;
    for line in contents.lines() {
        let line = line.trim().strip_prefix("export ").unwrap_or(line.trim());
        let Some((key, value)) = line.split_once('=') else { continue };
        if key.trim() != name {
            continue;
        }
        let value = value.trim().trim_matches(['"', '\'']).to_string();
        return (!value.is_empty()).then_some(value);
    }
    None
}

/// Last.fm issues 32-character hex API keys and shared secrets. A run of one
/// repeated character (`0000…`) is the placeholder shape that shipped a
/// silently unscrobbable build once already.
fn looks_like_credential(value: &str) -> bool {
    let value = value.trim();
    value.len() == 32
        && value.bytes().all(|byte| byte.is_ascii_hexdigit())
        && value.bytes().any(|byte| byte != value.as_bytes()[0])
}
