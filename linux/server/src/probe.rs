//! Looking at the local port: is it free, is it a Flaccy Server, and who else has it.

use std::time::Duration;

use serde_json::Value;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

use crate::runner::Runner;

const PROBE_TIMEOUT: Duration = Duration::from_secs(3);
const POLL_INTERVAL: Duration = Duration::from_millis(300);
const UNKNOWN_HOLDER: &str = "another program";

/// What is listening on a local port.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PortState {
    /// Nothing; the port can be bound.
    Free,
    /// A Flaccy Server answered `hello`.
    Flaccy,
    /// Something else, by name when it could be found.
    Taken(String),
}

/// Asks `GET /flaccy/v1/hello` on loopback; the JSON body when a Flaccy Server answered.
pub async fn hello(port: u16) -> Option<Value> {
    tokio::time::timeout(PROBE_TIMEOUT, ask_hello(port)).await.ok().flatten()
}

async fn ask_hello(port: u16) -> Option<Value> {
    let mut stream = TcpStream::connect(("127.0.0.1", port)).await.ok()?;
    let request = format!("GET /flaccy/v1/hello HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nConnection: close\r\n\r\n");
    stream.write_all(request.as_bytes()).await.ok()?;
    let mut raw = Vec::new();
    stream.read_to_end(&mut raw).await.ok()?;
    let text = String::from_utf8_lossy(&raw);
    let (head, body) = text.split_once("\r\n\r\n")?;
    if !head.starts_with("HTTP/1.1 200") {
        return None;
    }
    let json: Value = serde_json::from_str(json_object(body)?).ok()?;
    json.get("protocol").is_some().then_some(json)
}

/// The JSON object in a body, whatever chunk framing surrounds it.
fn json_object(body: &str) -> Option<&str> {
    body.get(body.find('{')?..=body.rfind('}')?)
}

/// Waits up to `timeout` for a Flaccy Server on `port`.
pub async fn wait_for_hello(port: u16, timeout: Duration) -> bool {
    let deadline = tokio::time::Instant::now() + timeout;
    loop {
        if hello(port).await.is_some() {
            return true;
        }
        if tokio::time::Instant::now() >= deadline {
            return false;
        }
        tokio::time::sleep(POLL_INTERVAL).await;
    }
}

/// Whether `port` on loopback is free, a Flaccy Server, or held by another program.
pub async fn port_state(port: u16, runner: &dyn Runner) -> Result<PortState, String> {
    match TcpListener::bind(("127.0.0.1", port)).await {
        Ok(_) => Ok(PortState::Free),
        Err(error) if error.kind() == std::io::ErrorKind::AddrInUse => {
            if hello(port).await.is_some() {
                Ok(PortState::Flaccy)
            } else {
                Ok(PortState::Taken(holder_name(port, runner)))
            }
        }
        Err(error) => Err(format!("Cannot listen on port {port}: {error}. Use --port with a number above 1024.")),
    }
}

fn holder_name(port: u16, runner: &dyn Runner) -> String {
    let sport = format!("sport = :{port}");
    let lsof_port = format!("-iTCP:{port}");
    let from_ss = runner.run("ss", &["-H", "-ltnp", &sport]).ok().and_then(|output| process_from_ss(&output.stdout));
    let from_lsof = || runner.run("lsof", &["-nP", &lsof_port, "-sTCP:LISTEN", "-Fc"]).ok().and_then(|output| process_from_lsof(&output.stdout));
    from_ss.or_else(from_lsof).unwrap_or_else(|| UNKNOWN_HOLDER.to_owned())
}

/// The program name in `ss -ltnp` output: `users:(("flaccy-server",pid=1,fd=8))`.
pub fn process_from_ss(output: &str) -> Option<String> {
    let after = output.split("users:((\"").nth(1)?;
    let name = after.split('"').next()?;
    (!name.is_empty()).then(|| name.to_owned())
}

/// The command name in `lsof -Fc` output: lines of `p<pid>` and `c<command>`.
pub fn process_from_lsof(output: &str) -> Option<String> {
    output.lines().find_map(|line| line.strip_prefix('c')).filter(|name| !name.is_empty()).map(str::to_owned)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::runner::fake::FakeRunner;

    #[test]
    fn ss_and_lsof_output_give_the_program_name() {
        let ss = "LISTEN 0 4096 127.0.0.1:4545 0.0.0.0:* users:((\"navidrome\",pid=812,fd=9))\n";
        assert_eq!(process_from_ss(ss).as_deref(), Some("navidrome"));
        assert_eq!(process_from_ss("LISTEN 0 4096 127.0.0.1:4545 0.0.0.0:*\n"), None);
        assert_eq!(process_from_lsof("p812\ncnavidrome\n").as_deref(), Some("navidrome"));
        assert_eq!(process_from_lsof(""), None);
    }

    #[tokio::test]
    async fn a_free_port_is_free_and_a_held_one_is_named() {
        let held = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = held.local_addr().unwrap().port();
        let runner = FakeRunner::default().on("ss", FakeRunner::ok("LISTEN 0 1 127.0.0.1:1 0.0.0.0:* users:((\"navidrome\",pid=1,fd=3))"));
        assert_eq!(port_state(port, &runner).await.unwrap(), PortState::Taken("navidrome".to_owned()));
        drop(held);
        assert_eq!(port_state(port, &runner).await.unwrap(), PortState::Free);
    }

    #[tokio::test]
    async fn a_holder_nobody_can_name_is_another_program() {
        let held = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = held.local_addr().unwrap().port();
        assert_eq!(port_state(port, &FakeRunner::default()).await.unwrap(), PortState::Taken(UNKNOWN_HOLDER.to_owned()));
    }

    #[tokio::test]
    async fn a_server_that_answers_hello_is_flaccy() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        tokio::spawn(async move {
            while let Ok((mut stream, _)) = listener.accept().await {
                let mut buffer = [0u8; 512];
                let _ = stream.read(&mut buffer).await;
                let body = r#"{"protocol":[1]}"#;
                let reply = format!("HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len());
                let _ = stream.write_all(reply.as_bytes()).await;
            }
        });
        assert_eq!(port_state(port, &FakeRunner::default()).await.unwrap(), PortState::Flaccy);
        assert!(wait_for_hello(port, Duration::from_millis(100)).await);
    }
}
