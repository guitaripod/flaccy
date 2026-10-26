//! `GET /flaccy/v1/live`: the WebSocket that pokes devices after a commit and
//! relays presence and commands between one user's devices (PROTOCOL.md section 9).

use std::time::Duration;

use axum::extract::ws::{CloseFrame, Message, WebSocket, WebSocketUpgrade};
use axum::extract::State;
use axum::http::HeaderMap;
use axum::response::Response;
use flaccy_library::logger;
use serde_json::{json, Map, Value};
use tokio::sync::watch;
use tokio::time::{interval_at, sleep_until, Instant, MissedTickBehavior};

use super::extract::{bearer_token, Authed};
use super::live_hub::{now_ms, LiveHub, LiveTiming, Outbound, Registration};
use super::ApiError;
use crate::security::{keys, Role};
use crate::state::AppState;
use crate::sync::{Poke, HOUSEHOLD_SCOPE};

/// The largest frame, in bytes; a bigger one closes the socket.
pub const MAX_FRAME_BYTES: usize = 64 * 1024;
const CATEGORY: &str = "live";
const SEND_TIMEOUT: Duration = Duration::from_secs(10);
const MAX_COMMAND_NAME: usize = 64;
const MAX_STATE_NAME: usize = 32;
const CLOSE_NORMAL: u16 = 1000;
const CLOSE_GOING_AWAY: u16 = 1001;
pub(super) const CLOSE_POLICY: u16 = 1008;
const CLOSE_TOO_BIG: u16 = 1009;

/// What the loop does after handling one event.
enum Flow {
    Continue,
    Close(u16, &'static str),
    Ended,
}

/// Who a connection acts as, kept current by re-validating its token.
struct Session {
    user: String,
    device: String,
    token: String,
    role: Role,
}

/// `GET /live`: upgrades to a WebSocket for an enrolled, approved device.
pub async fn upgrade(
    State(state): State<AppState>,
    caller: Authed,
    headers: HeaderMap,
    socket: WebSocketUpgrade,
) -> Result<Response, ApiError> {
    let principal = caller.active()?.clone();
    let device = principal.device.clone().ok_or_else(|| {
        ApiError::forbidden("The live channel needs a device token, and this request used an API key.")
            .hint("Enroll this device with `flaccy-server enroll --user <name>` and connect with the token it receives.")
    })?;
    let token = bearer_token(&headers).unwrap_or_default().to_owned();
    let session = Session {
        user: principal.user.to_string(),
        device: device.to_string(),
        token,
        role: principal.role,
    };
    let connection = Connection::new(state, session);
    let attachment = connection.attach();
    Ok(socket
        .max_message_size(MAX_FRAME_BYTES)
        .max_frame_size(MAX_FRAME_BYTES)
        .on_upgrade(move |socket| connection.run(socket, attachment)))
}

/// What a connection holds from the moment it is accepted.
struct Attachment {
    pokes: tokio::sync::broadcast::Receiver<Poke>,
    stopping: watch::Receiver<bool>,
    registration: Registration,
}

struct Connection {
    state: AppState,
    hub: LiveHub,
    timing: LiveTiming,
    session: Session,
}

impl Connection {
    fn new(state: AppState, session: Session) -> Self {
        let hub = state.0.live.clone();
        let timing = hub.timing();
        Self { state, hub, timing, session }
    }

    /// Subscribes to pokes and joins the hub before the 101 answer goes out, so no commit after it is missed.
    fn attach(&self) -> Attachment {
        Attachment {
            pokes: self.state.0.sync.subscribe(),
            stopping: self.hub.stopping(),
            registration: self.hub.register(&self.session.user, &self.session.device),
        }
    }

    async fn run(mut self, mut socket: WebSocket, mut attachment: Attachment) {
        let replay = std::mem::take(&mut attachment.registration.replay);
        for frame in replay {
            if !send(&mut socket, Message::Text(frame.into())).await {
                return;
            }
        }
        let flow = self.pump(&mut socket, &mut attachment).await;
        if let Flow::Close(code, reason) = flow {
            let frame = CloseFrame { code, reason: reason.into() };
            send(&mut socket, Message::Close(Some(frame))).await;
        }
    }

    async fn pump(&mut self, socket: &mut WebSocket, attachment: &mut Attachment) -> Flow {
        let Attachment { pokes, stopping, registration } = attachment;
        let mut ping = every(self.timing.ping);
        let mut revalidate = every(self.timing.revalidate);
        let silence = sleep_until(Instant::now() + self.timing.silence);
        tokio::pin!(silence);
        loop {
            let flow = tokio::select! {
                heard = socket.recv() => {
                    silence.as_mut().reset(Instant::now() + self.timing.silence);
                    match heard {
                        Some(Ok(message)) => self.on_message(socket, message).await,
                        Some(Err(error)) => return Self::on_receive_error(&error),
                        None => return Flow::Ended,
                    }
                }
                Some(outbound) = registration.outbox.recv() => self.on_outbound(socket, outbound).await,
                poke = pokes.recv() => self.on_poke(socket, poke, pokes).await,
                _ = ping.tick() => deliver(socket, Message::Ping(Vec::new().into())).await,
                _ = &mut silence => Flow::Close(CLOSE_NORMAL, "silent"),
                _ = revalidate.tick() => self.check_token().await,
                _ = stop_requested(stopping) => Flow::Close(CLOSE_GOING_AWAY, "server stopping"),
            };
            if !matches!(flow, Flow::Continue) {
                return flow;
            }
        }
    }

    fn on_receive_error(error: &axum::Error) -> Flow {
        let text = error.to_string();
        if text.contains("too long") || text.contains("Space limit") || text.contains("capacity") {
            return Flow::Close(CLOSE_TOO_BIG, "frame too large");
        }
        Flow::Ended
    }

    async fn on_outbound(&mut self, socket: &mut WebSocket, outbound: Outbound) -> Flow {
        match outbound {
            Outbound::Text(frame) => deliver(socket, Message::Text(frame.into())).await,
            Outbound::Close { code, reason } => Flow::Close(code, reason),
        }
    }

    async fn on_poke(
        &mut self,
        socket: &mut WebSocket,
        poke: Result<Poke, tokio::sync::broadcast::error::RecvError>,
        pokes: &mut tokio::sync::broadcast::Receiver<Poke>,
    ) -> Flow {
        let head = match poke {
            Ok(poke) => self.relevant_head(&poke).max(self.drain_pokes(pokes)),
            Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => self.current_head().await,
            Err(tokio::sync::broadcast::error::RecvError::Closed) => return Flow::Close(CLOSE_GOING_AWAY, "server stopping"),
        };
        match head {
            Some(head) => deliver(socket, Message::Text(json!({ "t": "poke", "head": head }).to_string().into())).await,
            None => Flow::Continue,
        }
    }

    fn relevant_head(&self, poke: &Poke) -> Option<i64> {
        (poke.scope == self.session.user || poke.scope == HOUSEHOLD_SCOPE).then_some(poke.head)
    }

    fn drain_pokes(&self, pokes: &mut tokio::sync::broadcast::Receiver<Poke>) -> Option<i64> {
        let mut head = None;
        while let Ok(poke) = pokes.try_recv() {
            head = head.max(self.relevant_head(&poke));
        }
        head
    }

    async fn current_head(&self) -> Option<i64> {
        self.state.0.sync.stats().await.ok().map(|stats| stats.head)
    }

    async fn check_token(&mut self) -> Flow {
        match self.state.0.security.authenticate(&self.session.token).await {
            Ok(Some(principal)) if principal.role != Role::Pending => {
                self.session.role = principal.role;
                Flow::Continue
            }
            Ok(_) => Flow::Close(CLOSE_POLICY, "token no longer valid"),
            Err(error) => {
                logger::warn(CATEGORY, &format!("could not re-check a device token: {error}"));
                Flow::Continue
            }
        }
    }

    async fn on_message(&mut self, socket: &mut WebSocket, message: Message) -> Flow {
        match message {
            Message::Text(text) if text.len() > MAX_FRAME_BYTES => Flow::Close(CLOSE_TOO_BIG, "frame too large"),
            Message::Text(text) => self.on_frame(socket, text.as_str()).await,
            Message::Binary(_) => reply_error(socket, "bad_frame", "Frames are JSON text.").await,
            Message::Close(_) => Flow::Close(CLOSE_NORMAL, "bye"),
            Message::Ping(_) | Message::Pong(_) => Flow::Continue,
        }
    }

    async fn on_frame(&mut self, socket: &mut WebSocket, text: &str) -> Flow {
        let Ok(Value::Object(frame)) = serde_json::from_str::<Value>(text) else {
            return reply_error(socket, "bad_frame", "A frame is a JSON object with a `t` field.").await;
        };
        match frame.get("t").and_then(Value::as_str) {
            Some("presence") => self.on_presence(socket, &frame).await,
            Some("command") => self.on_command(socket, &frame).await,
            _ => reply_error(socket, "bad_frame", "The `t` of a frame is `presence` or `command`.").await,
        }
    }

    async fn on_presence(&mut self, socket: &mut WebSocket, frame: &Map<String, Value>) -> Flow {
        let Some(state) = frame.get("state").and_then(Value::as_str).filter(|state| !state.is_empty() && state.len() <= MAX_STATE_NAME) else {
            return reply_error(socket, "bad_frame", "A presence frame needs a short `state` word.").await;
        };
        let relayed = json!({
            "t": "presence",
            "device": self.session.device,
            "state": state,
            "ref": frame.get("ref").cloned().unwrap_or(Value::Null),
            "positionMs": frame.get("positionMs").cloned().unwrap_or(Value::Null),
            "at": now_ms(),
        });
        self.hub.publish_presence(&self.session.user, &self.session.device, relayed.to_string());
        Flow::Continue
    }

    async fn on_command(&mut self, socket: &mut WebSocket, frame: &Map<String, Value>) -> Flow {
        if !self.hub.allow_command(&self.session.user, &self.session.device, std::time::Instant::now()) {
            return reply_error(socket, "rate_limited", "At most 5 commands per second per device; wait a moment and send it again.").await;
        }
        if let Flow::Close(code, reason) = self.check_token().await {
            return Flow::Close(code, reason);
        }
        let name = frame.get("name").and_then(Value::as_str).filter(|name| !name.is_empty() && name.len() <= MAX_COMMAND_NAME);
        let to = frame.get("to").and_then(Value::as_str);
        let (Some(name), Some(to)) = (name, to) else {
            return reply_error(socket, "bad_frame", "A command needs `to` (a device id) and a short `name`.").await;
        };
        let Ok(id) = keys::random_uuid() else {
            return reply_error(socket, "internal", "The server could not make an id for the command; send it again.").await;
        };
        let relayed = json!({
            "t": "command",
            "id": id,
            "from": self.session.device,
            "name": name,
            "args": frame.get("args").cloned().unwrap_or_else(|| json!({})),
            "sentAt": self.state.0.sync.now_ms(),
        });
        if self.hub.relay_command(&self.session.user, to, relayed.to_string()) {
            return Flow::Continue;
        }
        reply_error(socket, "target_offline", "That device is not connected right now; commands are never queued.").await
    }
}

async fn stop_requested(stopping: &mut watch::Receiver<bool>) {
    let _ = stopping.wait_for(|stop| *stop).await;
}

fn every(period: Duration) -> tokio::time::Interval {
    let mut timer = interval_at(Instant::now() + period, period);
    timer.set_missed_tick_behavior(MissedTickBehavior::Delay);
    timer
}

async fn reply_error(socket: &mut WebSocket, code: &str, message: &str) -> Flow {
    deliver(socket, Message::Text(json!({ "t": "error", "code": code, "message": message }).to_string().into())).await
}

async fn deliver(socket: &mut WebSocket, message: Message) -> Flow {
    if send(socket, message).await {
        Flow::Continue
    } else {
        Flow::Close(CLOSE_NORMAL, "send failed")
    }
}

async fn send(socket: &mut WebSocket, message: Message) -> bool {
    matches!(tokio::time::timeout(SEND_TIMEOUT, socket.send(message)).await, Ok(Ok(())))
}
