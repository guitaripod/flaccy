use super::link::{classify, Incoming};
use crate::events::AppEvent;
use crate::ui::servers::Prefill;
use crate::ui::Ui;
use gtk::prelude::*;
use std::cell::RefCell;
use std::rc::{Rc, Weak};

thread_local! {
    static WINDOW: RefCell<Weak<Ui>> = const { RefCell::new(Weak::new()) };
    static WAITING: RefCell<Vec<Incoming>> = const { RefCell::new(Vec::new()) };
}

/// The window exists: links that arrived before it open now.
pub fn register_ui(ui: &Rc<Ui>) {
    WINDOW.with(|window| *window.borrow_mut() = Rc::downgrade(ui));
    present_merge_when_ready(ui);
    let waiting = WAITING.with(|waiting| std::mem::take(&mut *waiting.borrow_mut()));
    for incoming in waiting {
        open_incoming(ui, incoming);
    }
}

fn present_merge_when_ready(ui: &Rc<Ui>) {
    let weak = Rc::downgrade(ui);
    ui.core.hub.clone().subscribe_widget(&ui.window, move |_, event| {
        if let (AppEvent::ServerMergeReady, Some(ui)) = (event, weak.upgrade()) {
            crate::ui::flaccy_server_merge::present(&ui);
        }
    });
}

/// A command line argument or a URL the desktop handed over. Anything that is not a server link is ignored.
pub fn deliver(text: &str) {
    let Some(incoming) = classify(text) else {
        return;
    };
    let ui = WINDOW.with(|window| window.borrow().upgrade());
    match ui {
        Some(ui) => open_incoming(&ui, incoming),
        None => WAITING.with(|waiting| waiting.borrow_mut().push(incoming)),
    }
}

/// Opens the sheet that belongs to the link, filled in.
pub fn open_incoming(ui: &Rc<Ui>, incoming: Incoming) {
    ui.window.present();
    match incoming {
        Incoming::FlaccyServer(link) => {
            crate::ui::flaccy_server_dialog::present(ui, Some(&link));
        }
        Incoming::Subsonic { url, key, name } => crate::ui::servers::present_add(
            ui,
            &Prefill {
                address: url,
                name: name.unwrap_or_default(),
                api_key: key,
            },
        ),
    }
}
