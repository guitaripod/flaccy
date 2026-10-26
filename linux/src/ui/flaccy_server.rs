use crate::events::AppEvent;
use crate::server_sync::{copy, Service};
use crate::ui::Ui;
use adw::prelude::*;
use gtk::glib;
use std::cell::RefCell;
use std::rc::Rc;

const STATUS_REFRESH_SECONDS: u32 = 30;

/// The Flaccy Server group of Preferences → Servers: the connected server with its status line, or an Add button when there is none.
pub fn group(ui: &Rc<Ui>) -> adw::PreferencesGroup {
    let group = adw::PreferencesGroup::builder()
        .title(copy::GROUP_TITLE)
        .build();
    let add = gtk::Button::builder()
        .child(
            &adw::ButtonContent::builder()
                .icon_name("list-add-symbolic")
                .label(copy::ADD_BUTTON)
                .build(),
        )
        .valign(gtk::Align::Center)
        .build();
    add.add_css_class("suggested-action");
    {
        let ui = Rc::clone(ui);
        add.connect_clicked(move |_| crate::ui::flaccy_server_dialog::present(&ui, None));
    }
    group.set_header_suffix(Some(&add));
    let listed: Rc<RefCell<Vec<adw::ActionRow>>> = Rc::default();
    fill(ui, &group, &add, &listed);
    {
        let ui = Rc::clone(ui);
        let listed = Rc::clone(&listed);
        let add = add.downgrade();
        ui.core.hub.clone().subscribe_widget(&group, move |group, event| {
            if let (AppEvent::ServerSyncChanged, Some(add)) = (event, add.upgrade()) {
                fill(&ui, group, &add, &listed);
            }
        });
    }
    keep_status_fresh(&group, ui, &listed);
    group
}

fn fill(
    ui: &Rc<Ui>,
    group: &adw::PreferencesGroup,
    add: &gtk::Button,
    listed: &RefCell<Vec<adw::ActionRow>>,
) {
    for old in listed.borrow_mut().drain(..) {
        group.remove(&old);
    }
    let service = ui.core.server_sync.get();
    let connected = service.is_some_and(|service| service.connected());
    add.set_visible(!connected && service.is_some());
    let row = match service {
        Some(service) if connected => server_row(ui, service),
        _ => empty_row(),
    };
    group.add(&row);
    listed.borrow_mut().push(row);
}

fn empty_row() -> adw::ActionRow {
    adw::ActionRow::builder()
        .title(copy::NOT_CONNECTED)
        .subtitle(copy::NOT_CONNECTED_DETAIL)
        .build()
}

fn server_row(ui: &Rc<Ui>, service: &Rc<Service>) -> adw::ActionRow {
    let row = adw::ActionRow::builder()
        .title(glib::markup_escape_text(&service.name()))
        .subtitle(glib::markup_escape_text(&service.row_line()))
        .activatable(true)
        .build();
    row.add_prefix(&gtk::Image::from_icon_name("emblem-synchronizing-symbolic"));
    let badge = gtk::Label::new(Some(copy::SYNC_BADGE));
    badge.add_css_class("caption-heading");
    badge.add_css_class("accent");
    badge.set_valign(gtk::Align::Center);
    row.add_suffix(&badge);
    row.add_suffix(&gtk::Image::from_icon_name("go-next-symbolic"));
    let ui = Rc::clone(ui);
    row.connect_activated(move |_| crate::ui::flaccy_server_detail::present(&ui));
    row
}

fn keep_status_fresh(
    anchor: &adw::PreferencesGroup,
    ui: &Rc<Ui>,
    listed: &Rc<RefCell<Vec<adw::ActionRow>>>,
) {
    let weak = anchor.downgrade();
    let ui = Rc::clone(ui);
    let listed = Rc::clone(listed);
    glib::timeout_add_seconds_local(STATUS_REFRESH_SECONDS, move || {
        if weak.upgrade().is_none() {
            return glib::ControlFlow::Break;
        }
        if let (Some(service), Some(row)) = (ui.core.server_sync.get(), listed.borrow().first()) {
            if service.connected() {
                row.set_subtitle(&glib::markup_escape_text(&service.row_line()));
            }
        }
        glib::ControlFlow::Continue
    });
}

/// The footer for people with no server. Closing it hides it for good.
pub fn nudge_group(ui: &Rc<Ui>) -> adw::PreferencesGroup {
    let group = adw::PreferencesGroup::new();
    let text = gtk::Label::builder()
        .label(copy::NUDGE)
        .wrap(true)
        .xalign(0.0)
        .hexpand(true)
        .build();
    text.add_css_class("dim-label");
    let dismiss = gtk::Button::builder()
        .label(copy::NUDGE_DISMISS)
        .tooltip_text(copy::NUDGE_DISMISS_TOOLTIP)
        .valign(gtk::Align::Center)
        .build();
    dismiss.add_css_class("flat");
    let body = gtk::Box::new(gtk::Orientation::Horizontal, 12);
    body.append(&text);
    body.append(&dismiss);
    group.add(&body);
    group.set_visible(nudge_wanted(ui));
    {
        let ui = Rc::clone(ui);
        let group = group.downgrade();
        dismiss.connect_clicked(move |_| {
            ui.core.config.borrow_mut().flaccy_server_nudge_dismissed = true;
            ui.core.save_config();
            if let Some(group) = group.upgrade() {
                group.set_visible(false);
            }
        });
    }
    {
        let ui = Rc::clone(ui);
        ui.core.hub.clone().subscribe_widget(&group, move |group, event| {
            if matches!(event, AppEvent::ServerSyncChanged) {
                group.set_visible(nudge_wanted(&ui));
            }
        });
    }
    group
}

fn nudge_wanted(ui: &Rc<Ui>) -> bool {
    let service = ui.core.server_sync.get();
    service.is_some_and(|service| !service.connected())
        && !ui.core.config.borrow().flaccy_server_nudge_dismissed
}
