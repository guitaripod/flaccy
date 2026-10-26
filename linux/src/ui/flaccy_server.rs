use crate::events::AppEvent;
use crate::server_sync::{copy, status_line, Service};
use crate::ui::Ui;
use adw::prelude::*;
use flaccy_library::server_sync::DeviceInfo;
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
        .subtitle(glib::markup_escape_text(&service.status_line()))
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
    row.connect_activated(move |_| present_detail(&ui));
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
                row.set_subtitle(&glib::markup_escape_text(&service.status_line()));
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

/// The connected server's page: its status, the account's devices and Disconnect.
pub fn present_detail(ui: &Rc<Ui>) {
    let Some(service) = ui.core.server_sync.get().cloned() else {
        return;
    };
    let status_row = adw::ActionRow::builder()
        .title(copy::DETAIL_TITLE_STATUS)
        .subtitle(glib::markup_escape_text(&service.status_line()))
        .build();
    let synced_row = adw::ActionRow::builder()
        .title(copy::DETAIL_LAST_SYNCED)
        .subtitle(last_synced_text(&service))
        .build();
    let status_group = adw::PreferencesGroup::new();
    status_group.add(&status_row);
    status_group.add(&synced_row);
    let devices_group = adw::PreferencesGroup::builder()
        .title(copy::DEVICES_TITLE)
        .build();
    let loading = adw::ActionRow::builder()
        .title(copy::DEVICES_LOADING)
        .build();
    devices_group.add(&loading);
    let disconnect = gtk::Button::with_label(copy::DISCONNECT_BUTTON);
    disconnect.add_css_class("destructive-action");
    disconnect.add_css_class("pill");
    disconnect.set_halign(gtk::Align::Center);
    let page = adw::PreferencesPage::new();
    page.add(&status_group);
    page.add(&devices_group);
    let footer = adw::PreferencesGroup::new();
    footer.add(&disconnect);
    page.add(&footer);
    let toolbar = adw::ToolbarView::new();
    toolbar.add_top_bar(&adw::HeaderBar::new());
    toolbar.set_content(Some(&page));
    let dialog = adw::Dialog::builder()
        .title(glib::markup_escape_text(&service.name()))
        .content_width(480)
        .content_height(560)
        .child(&toolbar)
        .build();

    {
        let service = Rc::clone(&service);
        let dialog = dialog.downgrade();
        let (status_row, synced_row) = (status_row.downgrade(), synced_row.downgrade());
        ui.core.hub.clone().subscribe_widget(&page, move |_, event| {
            if !matches!(event, AppEvent::ServerSyncChanged) {
                return;
            }
            if !service.connected() {
                if let Some(dialog) = dialog.upgrade() {
                    dialog.close();
                }
                return;
            }
            if let (Some(status_row), Some(synced_row)) = (status_row.upgrade(), synced_row.upgrade()) {
                announce_if_changed(&status_row, &service.status_line());
                synced_row.set_subtitle(&last_synced_text(&service));
            }
        });
    }
    {
        let ui = Rc::clone(ui);
        let dialog = dialog.clone();
        disconnect.connect_clicked(move |_| confirm_disconnect(&ui, &dialog));
    }
    load_devices(&service, &devices_group, loading);
    dialog.present(Some(&ui.window));
}

/// Writes the status line into its row and, when the words changed, tells assistive technology: the line is a live region.
fn announce_if_changed(row: &adw::ActionRow, line: &str) {
    let escaped = glib::markup_escape_text(line);
    if row.subtitle().as_deref() == Some(escaped.as_str()) {
        return;
    }
    row.set_subtitle(&escaped);
    row.upcast_ref::<gtk::Widget>().announce(line, gtk::AccessibleAnnouncementPriority::Low);
}

fn last_synced_text(service: &Service) -> String {
    match service.last_synced_at() {
        Some(at) => status_line::ago(chrono::Utc::now().timestamp_millis() - at),
        None => copy::DETAIL_NEVER_SYNCED.to_owned(),
    }
}

fn load_devices(service: &Rc<Service>, group: &adw::PreferencesGroup, loading: adw::ActionRow) {
    let service = Rc::clone(service);
    let group = group.clone();
    glib::spawn_future_local(async move {
        let result = service.devices().await;
        group.remove(&loading);
        match result {
            Ok(devices) => devices
                .iter()
                .for_each(|device| group.add(&device_row(device))),
            Err(failure) => group.add(
                &adw::ActionRow::builder()
                    .title(glib::markup_escape_text(&failure.title))
                    .subtitle(glib::markup_escape_text(&copy::devices_failed(&failure.body)))
                    .build(),
            ),
        }
    });
}

fn device_row(device: &DeviceInfo) -> adw::ActionRow {
    let seen = match (device.current, device.last_seen_at) {
        (true, _) => copy::THIS_DEVICE.to_owned(),
        (false, Some(at)) => copy::last_seen(&status_line::ago(
            chrono::Utc::now().timestamp_millis() - at,
        )),
        (false, None) => copy::NEVER_SEEN.to_owned(),
    };
    adw::ActionRow::builder()
        .title(glib::markup_escape_text(&device.name))
        .subtitle(glib::markup_escape_text(&copy::device_subtitle(
            &copy::platform_label(&device.platform),
            &seen,
        )))
        .build()
}

fn confirm_disconnect(ui: &Rc<Ui>, detail: &adw::Dialog) {
    let Some(service) = ui.core.server_sync.get().cloned() else {
        return;
    };
    let name = service.name();
    let alert = adw::AlertDialog::builder()
        .heading(copy::disconnect_title(&name))
        .body(copy::disconnect_body(&name))
        .close_response("cancel")
        .default_response("cancel")
        .build();
    alert.add_response("cancel", copy::CANCEL_BUTTON);
    alert.add_response("disconnect", copy::DISCONNECT_CONFIRM_BUTTON);
    alert.set_response_appearance("disconnect", adw::ResponseAppearance::Destructive);
    let parent = ui.window.clone();
    let ui = Rc::clone(ui);
    let detail = detail.clone();
    alert.connect_response(None, move |_, response| {
        if response != "disconnect" {
            return;
        }
        let (ui, detail, service) = (Rc::clone(&ui), detail.clone(), Rc::clone(&service));
        glib::spawn_future_local(async move {
            match service.disconnect().await {
                Ok(()) => {
                    detail.close();
                    ui.core.toast(copy::DISCONNECTED_TOAST);
                }
                Err(message) => ui.core.toast(&message),
            }
        });
    });
    alert.present(Some(&parent));
}
