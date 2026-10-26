use crate::events::AppEvent;
use crate::server_sync::{copy, status_line, Service};
use crate::ui::Ui;
use adw::prelude::*;
use flaccy_library::server_sync::DeviceInfo;
use gtk::glib;
use std::cell::{Cell, RefCell};
use std::rc::Rc;

/// The connected server's page: its status, its music in the library, the account's devices and Disconnect.
pub fn present(ui: &Rc<Ui>) {
    let Some(service) = ui.core.server_sync.get().cloned() else {
        return;
    };
    let (page, dialog) = Page::build(ui, service);
    page.watch();
    page.reload_devices();
    dialog.present(Some(&ui.window));
}

struct Page {
    ui: Rc<Ui>,
    service: Rc<Service>,
    dialog: glib::WeakRef<adw::Dialog>,
    group_anchor: adw::PreferencesPage,
    status_row: adw::ActionRow,
    synced_row: adw::ActionRow,
    songs_row: adw::ActionRow,
    visible_row: adw::SwitchRow,
    devices_group: adw::PreferencesGroup,
    device_rows: RefCell<Vec<adw::ActionRow>>,
    syncing_switch: Cell<bool>,
}

impl Page {
    fn build(ui: &Rc<Ui>, service: Rc<Service>) -> (Rc<Page>, adw::Dialog) {
        let name = service.name();
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

        let songs_row = adw::ActionRow::builder().title(copy::LIBRARY_TITLE).build();
        let visible_row = adw::SwitchRow::builder()
            .title(glib::markup_escape_text(&copy::show_music_title(&name)))
            .build();
        let library_group = adw::PreferencesGroup::new();
        library_group.add(&songs_row);
        library_group.add(&visible_row);

        let devices_group = adw::PreferencesGroup::builder()
            .title(copy::DEVICES_TITLE)
            .build();
        let disconnect = gtk::Button::with_label(copy::DISCONNECT_BUTTON);
        disconnect.add_css_class("destructive-action");
        disconnect.add_css_class("pill");
        disconnect.set_halign(gtk::Align::Center);
        let footer = adw::PreferencesGroup::new();
        footer.add(&disconnect);

        let preferences = adw::PreferencesPage::new();
        preferences.add(&status_group);
        preferences.add(&library_group);
        preferences.add(&devices_group);
        preferences.add(&footer);
        let toolbar = adw::ToolbarView::new();
        toolbar.add_top_bar(&adw::HeaderBar::new());
        toolbar.set_content(Some(&preferences));
        let dialog = adw::Dialog::builder()
            .title(glib::markup_escape_text(&name))
            .content_width(480)
            .content_height(640)
            .child(&toolbar)
            .build();

        let page = Rc::new(Page {
            ui: Rc::clone(ui),
            service,
            dialog: dialog.downgrade(),
            group_anchor: preferences,
            status_row,
            synced_row,
            songs_row,
            visible_row,
            devices_group,
            device_rows: RefCell::new(Vec::new()),
            syncing_switch: Cell::new(false),
        });
        page.refresh_library();
        page.wire(&disconnect);
        let owner = Rc::clone(&page);
        dialog.connect_closed(move |_| {
            let _ = &owner;
        });
        (page, dialog)
    }

    fn close(&self) {
        if let Some(dialog) = self.dialog.upgrade() {
            dialog.close();
        }
    }

    fn wire(self: &Rc<Self>, disconnect: &gtk::Button) {
        let this = Rc::downgrade(self);
        disconnect.connect_clicked(move |_| {
            if let Some(this) = this.upgrade() {
                this.confirm_disconnect();
            }
        });
        let this = Rc::downgrade(self);
        self.visible_row.connect_active_notify(move |row| {
            if let Some(this) = this.upgrade() {
                this.library_switched(row.is_active());
            }
        });
    }

    fn watch(self: &Rc<Self>) {
        let this = Rc::downgrade(self);
        self.ui
            .core
            .hub
            .clone()
            .subscribe_widget(&self.group_anchor, move |_, event| {
                if !matches!(event, AppEvent::ServerSyncChanged) {
                    return;
                }
                if let Some(this) = this.upgrade() {
                    this.refresh();
                }
            });
    }

    fn refresh(&self) {
        if !self.service.connected() {
            self.close();
            return;
        }
        announce_if_changed(&self.status_row, &self.service.status_line());
        self.synced_row
            .set_subtitle(&last_synced_text(&self.service));
        self.refresh_library();
    }

    fn refresh_library(&self) {
        let visible = self.service.library_visible();
        self.songs_row.set_subtitle(&glib::markup_escape_text(&copy::library_line(
            visible,
            self.service.library_songs(),
            self.service.library_trouble(),
            &self.service.name(),
        )));
        if self.visible_row.is_active() != visible {
            self.syncing_switch.set(true);
            self.visible_row.set_active(visible);
            self.syncing_switch.set(false);
        }
    }

    fn library_switched(self: &Rc<Self>, active: bool) {
        if self.syncing_switch.get() || active == self.service.library_visible() {
            return;
        }
        let this = Rc::clone(self);
        glib::spawn_future_local(async move {
            if let Err(message) = this.service.show_library(active).await {
                this.ui.core.toast(&message);
                this.refresh_library();
            }
        });
    }

    fn reload_devices(self: &Rc<Self>) {
        let loading = adw::ActionRow::builder()
            .title(copy::DEVICES_LOADING)
            .build();
        self.clear_devices();
        self.devices_group.add(&loading);
        self.device_rows.borrow_mut().push(loading);
        let this = Rc::clone(self);
        glib::spawn_future_local(async move {
            let result = this.service.devices().await;
            this.clear_devices();
            match result {
                Ok(devices) => devices.iter().for_each(|device| this.add_device(device)),
                Err(failure) => this.add_row(
                    adw::ActionRow::builder()
                        .title(glib::markup_escape_text(&failure.title))
                        .subtitle(glib::markup_escape_text(&copy::devices_failed(&failure.body)))
                        .build(),
                ),
            }
        });
    }

    fn clear_devices(&self) {
        for row in self.device_rows.borrow_mut().drain(..) {
            self.devices_group.remove(&row);
        }
    }

    fn add_row(&self, row: adw::ActionRow) {
        self.devices_group.add(&row);
        self.device_rows.borrow_mut().push(row);
    }

    fn add_device(self: &Rc<Self>, device: &DeviceInfo) {
        let row = device_row(device);
        let (icon, tooltip) = if device.current {
            ("document-edit-symbolic", copy::RENAME_TOOLTIP)
        } else {
            ("user-trash-symbolic", copy::REMOVE_TOOLTIP)
        };
        let button = gtk::Button::builder()
            .icon_name(icon)
            .tooltip_text(tooltip)
            .valign(gtk::Align::Center)
            .build();
        button.add_css_class("flat");
        button.update_property(&[gtk::accessible::Property::Label(tooltip)]);
        let (this, device) = (Rc::downgrade(self), device.clone());
        button.connect_clicked(move |_| {
            let Some(this) = this.upgrade() else { return };
            if device.current {
                this.ask_rename(&device);
            } else {
                this.ask_remove(&device);
            }
        });
        row.add_suffix(&button);
        self.add_row(row);
    }

    fn ask_rename(self: &Rc<Self>, device: &DeviceInfo) {
        let entry = gtk::Entry::builder()
            .text(&device.name)
            .activates_default(true)
            .build();
        let alert = adw::AlertDialog::builder()
            .heading(copy::RENAME_TITLE)
            .body(copy::rename_body(&self.service.name()))
            .close_response("cancel")
            .default_response("rename")
            .extra_child(&entry)
            .build();
        alert.add_response("cancel", copy::CANCEL_BUTTON);
        alert.add_response("rename", copy::RENAME_BUTTON);
        alert.set_response_appearance("rename", adw::ResponseAppearance::Suggested);
        let (this, id) = (Rc::clone(self), device.id.clone());
        alert.connect_response(None, move |_, response| {
            let name = entry.text().trim().to_owned();
            if response != "rename" {
                return;
            }
            if name.is_empty() {
                this.ui.core.toast(copy::RENAME_EMPTY);
                return;
            }
            this.rename(id.clone(), name);
        });
        alert.present(Some(&self.ui.window));
    }

    fn rename(self: &Rc<Self>, id: String, name: String) {
        let this = Rc::clone(self);
        glib::spawn_future_local(async move {
            match this.service.rename_device(&id, &name).await {
                Ok(()) => this.reload_devices(),
                Err(failure) => this.toast_failure(&failure),
            }
        });
    }

    fn ask_remove(self: &Rc<Self>, device: &DeviceInfo) {
        let server = self.service.name();
        let alert = adw::AlertDialog::builder()
            .heading(copy::remove_title(&device.name))
            .body(copy::remove_body(&device.name, &server))
            .close_response("cancel")
            .default_response("cancel")
            .build();
        alert.add_response("cancel", copy::CANCEL_BUTTON);
        alert.add_response("remove", copy::REMOVE_BUTTON);
        alert.set_response_appearance("remove", adw::ResponseAppearance::Destructive);
        let (this, id) = (Rc::clone(self), device.id.clone());
        alert.connect_response(None, move |_, response| {
            if response != "remove" {
                return;
            }
            let (this, id) = (Rc::clone(&this), id.clone());
            glib::spawn_future_local(async move {
                match this.service.remove_device(&id).await {
                    Ok(()) => this.reload_devices(),
                    Err(failure) => this.toast_failure(&failure),
                }
            });
        });
        alert.present(Some(&self.ui.window));
    }

    fn toast_failure(&self, failure: &crate::server_sync::failure::Failure) {
        self.ui
            .core
            .toast(&format!("{} {}", failure.title, failure.body));
    }

    fn confirm_disconnect(self: &Rc<Self>) {
        let name = self.service.name();
        let alert = adw::AlertDialog::builder()
            .heading(copy::disconnect_title(&name))
            .body(copy::disconnect_body(&name))
            .close_response("cancel")
            .default_response("cancel")
            .build();
        alert.add_response("cancel", copy::CANCEL_BUTTON);
        alert.add_response("disconnect", copy::DISCONNECT_CONFIRM_BUTTON);
        alert.set_response_appearance("disconnect", adw::ResponseAppearance::Destructive);
        let this = Rc::clone(self);
        alert.connect_response(None, move |_, response| {
            if response != "disconnect" {
                return;
            }
            let this = Rc::clone(&this);
            glib::spawn_future_local(async move {
                match this.service.disconnect().await {
                    Ok(()) => {
                        this.close();
                        this.ui.core.toast(copy::DISCONNECTED_TOAST);
                    }
                    Err(message) => this.ui.core.toast(&message),
                }
            });
        });
        alert.present(Some(&self.ui.window));
    }
}

/// Writes the status line into its row and, when the words changed, tells assistive technology: the line is a live region.
fn announce_if_changed(row: &adw::ActionRow, line: &str) {
    let escaped = glib::markup_escape_text(line);
    if row.subtitle().as_deref() == Some(escaped.as_str()) {
        return;
    }
    row.set_subtitle(&escaped);
    row.upcast_ref::<gtk::Widget>()
        .announce(line, gtk::AccessibleAnnouncementPriority::Low);
}

fn last_synced_text(service: &Service) -> String {
    match service.last_synced_at() {
        Some(at) => status_line::ago(chrono::Utc::now().timestamp_millis() - at),
        None => copy::DETAIL_NEVER_SYNCED.to_owned(),
    }
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
