use super::{address, Service, LOG};
use flaccy_library::server_sync::ServerLink;
use gtk::glib;
use std::rc::Rc;
use std::time::Duration;

const CONNECT_DELAY: Duration = Duration::from_millis(1_000);
const WRONG_CODE: &str = "ZZZZZZZZZZZZZZZZZZZZZZZZZZ";

/// Demo mode: `FLACCY_DEMO_SERVER='<address>|<code>'` connects to that server on start (unless `FLACCY_DEMO_SERVER_UI` asks to show the dialog instead), against the throwaway XDG directories the other `FLACCY_DEMO_*` switches use, so screenshots and drives run unattended. The code is never logged.
pub fn start(service: &Rc<Service>) {
    let ui_demo = std::env::var_os("FLACCY_DEMO_SERVER_UI").is_some();
    if !crate::config::demo_mode() || service.connected() || ui_demo {
        return;
    }
    let Some(link) = std::env::var("FLACCY_DEMO_SERVER")
        .ok()
        .and_then(|spec| link_from(&spec))
    else {
        return;
    };
    let service = Rc::clone(service);
    glib::timeout_add_local_once(CONNECT_DELAY, move || {
        glib::spawn_future_local(async move {
            match service.connect(link).await {
                Ok(connected) => crate::logger::info(
                    LOG,
                    &format!("DEMO SERVER CONNECTED to {}", connected.server.name),
                ),
                Err(failure) => crate::logger::error(
                    LOG,
                    &format!("DEMO SERVER FAILED: {} {}", failure.title, failure.body),
                ),
            }
        });
    });
}

/// Demo mode: `FLACCY_DEMO_SERVER_UI` opens one state of the interface for a screenshot. `dialog` is the empty sheet, `filled` the sheet with `FLACCY_DEMO_SERVER` typed in, `drive` the same after pressing Connect, `wrong` presses Connect with a code the server never issued, and `detail` is the connected server's page.
pub fn open_ui(ui: &Rc<crate::ui::Ui>, mode: &str) {
    let link = std::env::var("FLACCY_DEMO_SERVER")
        .ok()
        .and_then(|spec| link_from(&spec));
    match (mode, link) {
        ("dialog", _) => crate::ui::flaccy_server_dialog::present(ui, None),
        ("filled", Some(link)) => crate::ui::flaccy_server_dialog::present(ui, Some(&link)),
        ("drive", Some(link)) => crate::ui::flaccy_server_dialog::present_with(ui, Some(&link), true),
        ("wrong", Some(link)) => {
            let wrong = ServerLink::new(&link.url, Some(WRONG_CODE), None);
            crate::ui::flaccy_server_dialog::present_with(ui, Some(&wrong), true);
        }
        ("detail", _) => crate::ui::flaccy_server_detail::present(ui),
        _ => crate::logger::warn(LOG, "FLACCY_DEMO_SERVER_UI needs dialog, filled, drive, wrong or detail"),
    }
}

fn link_from(spec: &str) -> Option<ServerLink> {
    let (typed, code) = spec.split_once('|')?;
    let url = address::typed_address(typed)?;
    Some(ServerLink::new(
        &url,
        Some(&address::canonical_code(code)),
        None,
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_demo_spec_is_an_address_and_a_code() {
        let link = link_from("http://127.0.0.1:4545|abcd-efgh").unwrap();
        assert_eq!(link.url, "http://127.0.0.1:4545");
        assert_eq!(link.enroll.as_deref(), Some("ABCDEFGH"));
        assert!(link_from("nocode").is_none());
    }
}
