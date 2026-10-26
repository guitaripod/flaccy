use crate::server_sync::failure::{Failure, Remedy};
use crate::server_sync::link::{resolve_form, Request};
use crate::server_sync::{address, copy, Service};
use crate::ui::servers::Prefill;
use crate::ui::Ui;
use adw::prelude::*;
use flaccy_library::server_sync::ServerLink;
use gtk::glib;
use std::cell::{Cell, RefCell};
use std::rc::Rc;

const PAGE_FORM: &str = "form";
const PAGE_CHECKING: &str = "checking";
const PAGE_CONNECTED: &str = "connected";
const PAGE_FAILED: &str = "failed";

/// Opens Add Flaccy Server, with its fields filled from `link` when the person arrived through one. The link is never connected to without the Connect button: it sends this computer's playlists and history to whoever runs the server.
pub fn present(ui: &Rc<Ui>, link: Option<&ServerLink>) {
    present_with(ui, link, false);
}

/// The same, and when `connect_now` is set also presses Connect: the demo hooks drive the dialog this way.
pub fn present_with(ui: &Rc<Ui>, link: Option<&ServerLink>, connect_now: bool) {
    let Some(service) = ui.core.server_sync.get().cloned() else {
        ui.core.toast(copy::SERVICE_UNAVAILABLE);
        return;
    };
    let (form, widget) = Dialog::build(ui, service);
    if let Some(link) = link {
        form.fill(link);
    }
    widget.present(Some(&ui.window));
    if connect_now {
        form.submit();
    }
}

struct Dialog {
    ui: Rc<Ui>,
    service: Rc<Service>,
    dialog: glib::WeakRef<adw::Dialog>,
    stack: gtk::Stack,
    link_row: adw::EntryRow,
    expander: adw::ExpanderRow,
    address_row: adw::EntryRow,
    code_row: adw::EntryRow,
    form_status: gtk::Label,
    connect: gtk::Button,
    checking_label: gtk::Label,
    connected_title: gtk::Label,
    failed_title: gtk::Label,
    failed_body: gtk::Label,
    failed_actions: gtk::Box,
    offered_name: RefCell<Option<String>>,
    formatting: Cell<bool>,
}

impl Dialog {
    fn build(ui: &Rc<Ui>, service: Rc<Service>) -> (Rc<Dialog>, adw::Dialog) {
        let link_row = adw::EntryRow::builder()
            .title(copy::LINK_ROW_TITLE)
            .build();
        let address_row = adw::EntryRow::builder()
            .title(copy::ADDRESS_ROW_TITLE)
            .input_purpose(gtk::InputPurpose::Url)
            .build();
        let code_row = adw::EntryRow::builder().title(copy::CODE_ROW_TITLE).build();
        code_row.set_input_purpose(gtk::InputPurpose::FreeForm);
        let expander = adw::ExpanderRow::builder()
            .title(copy::TYPE_INSTEAD)
            .build();
        expander.add_row(&address_row);
        expander.add_row(&code_row);
        let fields = adw::PreferencesGroup::new();
        fields.add(&link_row);
        fields.add(&expander);

        let form_status = gtk::Label::builder()
            .wrap(true)
            .xalign(0.0)
            .visible(false)
            .build();
        form_status.add_css_class("error");
        let connect = gtk::Button::with_label(copy::CONNECT_BUTTON);
        connect.add_css_class("suggested-action");
        connect.set_sensitive(false);
        let cancel = gtk::Button::with_label(copy::CANCEL_BUTTON);
        let buttons = button_row(&[&cancel, &connect]);
        let form = page_box(&[fields.upcast_ref(), form_status.upcast_ref(), buttons.upcast_ref()]);

        let checking_label = gtk::Label::builder().wrap(true).build();
        let spinner = adw::Spinner::builder()
            .width_request(32)
            .height_request(32)
            .build();
        let checking = centered(&[spinner.upcast_ref(), checking_label.upcast_ref()]);

        let connected_title = heading_label();
        let connected_body = body_label(copy::CONNECTED_BODY);
        let done = gtk::Button::with_label(copy::DONE_BUTTON);
        done.add_css_class("suggested-action");
        let connected = centered(&[
            icon("emblem-ok-symbolic", "success").upcast_ref(),
            connected_title.upcast_ref(),
            connected_body.upcast_ref(),
            done.upcast_ref(),
        ]);

        let failed_title = heading_label();
        let failed_body = body_label("");
        let failed_actions = button_row(&[]);
        let failed = centered(&[
            icon("dialog-warning-symbolic", "warning").upcast_ref(),
            failed_title.upcast_ref(),
            failed_body.upcast_ref(),
            failed_actions.upcast_ref(),
        ]);

        let stack = gtk::Stack::builder()
            .transition_type(gtk::StackTransitionType::Crossfade)
            .vhomogeneous(false)
            .build();
        stack.add_named(&form, Some(PAGE_FORM));
        stack.add_named(&checking, Some(PAGE_CHECKING));
        stack.add_named(&connected, Some(PAGE_CONNECTED));
        stack.add_named(&failed, Some(PAGE_FAILED));

        let toolbar = adw::ToolbarView::new();
        toolbar.add_top_bar(&adw::HeaderBar::new());
        toolbar.set_content(Some(&stack));
        let dialog = adw::Dialog::builder()
            .title(copy::DIALOG_TITLE)
            .content_width(460)
            .child(&toolbar)
            .build();

        let this = Rc::new(Dialog {
            ui: Rc::clone(ui),
            service,
            dialog: dialog.downgrade(),
            stack,
            link_row,
            expander,
            address_row,
            code_row,
            form_status,
            connect: connect.clone(),
            checking_label,
            connected_title,
            failed_title,
            failed_body,
            failed_actions,
            offered_name: RefCell::new(None),
            formatting: Cell::new(false),
        });
        this.wire(&cancel, &done);
        let owner = Rc::clone(&this);
        dialog.connect_closed(move |_| {
            let _ = &owner;
        });
        (this, dialog)
    }

    fn wire(self: &Rc<Self>, cancel: &gtk::Button, done: &gtk::Button) {
        for button in [cancel, done] {
            let this = Rc::downgrade(self);
            button.connect_clicked(move |_| {
                if let Some(this) = this.upgrade() {
                    this.close();
                }
            });
        }
        let this = Rc::downgrade(self);
        self.connect.connect_clicked(move |_| {
            if let Some(this) = this.upgrade() {
                this.submit();
            }
        });
        for row in [&self.link_row, &self.address_row] {
            let this = Rc::downgrade(self);
            row.connect_changed(move |_| {
                if let Some(this) = this.upgrade() {
                    this.fields_changed();
                }
            });
        }
        let this = Rc::downgrade(self);
        self.code_row.connect_changed(move |row| {
            if let Some(this) = this.upgrade() {
                this.regroup_code(row);
                this.fields_changed();
            }
        });
        for row in [&self.link_row, &self.code_row] {
            let this = Rc::downgrade(self);
            row.connect_entry_activated(move |_| {
                if let Some(this) = this.upgrade() {
                    this.submit();
                }
            });
        }
    }

    fn close(&self) {
        if let Some(dialog) = self.dialog.upgrade() {
            dialog.close();
        }
    }

    fn fill(&self, link: &ServerLink) {
        *self.offered_name.borrow_mut() = link.name.clone();
        self.address_row.set_text(&link.url);
        if let Some(code) = &link.enroll {
            self.code_row.set_text(&address::format_code(code));
        }
        self.expander.set_expanded(true);
    }

    fn regroup_code(&self, row: &adw::EntryRow) {
        if self.formatting.replace(true) {
            return;
        }
        let typed = row.text().to_string();
        let grouped = address::format_code(&typed);
        if grouped != typed {
            let cursor = address::cursor_after_format(&typed, row.position().max(0) as usize);
            row.set_text(&grouped);
            row.set_position(cursor as i32);
        }
        self.formatting.set(false);
    }

    fn fields_changed(&self) {
        self.form_status.set_visible(false);
        let has_link = !self.link_row.text().trim().is_empty();
        let has_address = !self.address_row.text().trim().is_empty();
        self.connect.set_sensitive(has_link || has_address);
    }

    fn show_form_error(&self, message: &str) {
        self.form_status.set_label(message);
        self.form_status.set_visible(true);
        announce(&self.form_status, message);
    }

    fn show(&self, page: &str) {
        self.stack.set_visible_child_name(page);
        if let Some(dialog) = self.dialog.upgrade() {
            dialog.set_can_close(page != PAGE_CHECKING);
        }
    }

    fn submit(self: &Rc<Self>) {
        let request = resolve_form(
            &self.link_row.text(),
            &self.address_row.text(),
            &self.code_row.text(),
            self.offered_name.borrow().as_deref(),
        );
        match request {
            Err(message) => self.show_form_error(message),
            Ok(Request::OtherServer(incoming)) => self.hand_to_regular_sheet(incoming),
            Ok(Request::Connect(link)) => self.begin_connect(link),
            Ok(Request::Probe(url)) => self.begin_probe(url),
        }
    }

    fn hand_to_regular_sheet(&self, incoming: crate::server_sync::link::Incoming) {
        self.close();
        crate::server_sync::open_incoming(&self.ui, incoming);
    }

    fn begin_connect(self: &Rc<Self>, link: ServerLink) {
        let name = link
            .name
            .clone()
            .unwrap_or_else(|| address::short_name(&link.url));
        self.show_checking(&name);
        let this = Rc::clone(self);
        glib::spawn_future_local(async move {
            let result = this.service.connect(link).await;
            match result {
                Ok(connected) => this.show_connected(&connected.server.name),
                Err(failure) => this.show_failure(&failure, &this.address_row.text()),
            }
        });
    }

    fn begin_probe(self: &Rc<Self>, url: String) {
        let name = address::short_name(&url);
        self.show_checking(&name);
        let this = Rc::clone(self);
        glib::spawn_future_local(async move {
            match this.service.probe(&url).await {
                Ok(identity) => {
                    this.show(PAGE_FORM);
                    this.expander.set_expanded(true);
                    this.show_form_error(&copy::code_needed(&identity.name));
                    this.code_row.grab_focus();
                }
                Err(failure) => this.show_failure(&failure, &url),
            }
        });
    }

    fn show_checking(&self, name: &str) {
        let message = copy::checking(name);
        self.checking_label.set_label(&message);
        self.show(PAGE_CHECKING);
        announce(&self.checking_label, &message);
    }

    fn show_connected(&self, name: &str) {
        let title = copy::connected_title(name);
        self.connected_title.set_label(&title);
        self.show(PAGE_CONNECTED);
        announce(&self.connected_title, &title);
    }

    fn show_failure(self: &Rc<Self>, failure: &Failure, typed_address: &str) {
        self.failed_title.set_label(&failure.title);
        self.failed_body.set_label(&failure.body);
        while let Some(child) = self.failed_actions.first_child() {
            self.failed_actions.remove(&child);
        }
        match failure.remedy {
            Remedy::AddAsRegular => self.offer_regular_sheet(typed_address),
            Remedy::TryAgain => self.offer_back(copy::TRY_AGAIN_BUTTON),
            Remedy::Ok => self.offer_back(copy::OK_BUTTON),
        }
        self.show(PAGE_FAILED);
        announce(&self.failed_title, &format!("{} {}", failure.title, failure.body));
    }

    fn offer_back(self: &Rc<Self>, label: &str) {
        let back = gtk::Button::with_label(label);
        back.add_css_class("suggested-action");
        let this = Rc::downgrade(self);
        back.connect_clicked(move |_| {
            if let Some(this) = this.upgrade() {
                this.show(PAGE_FORM);
            }
        });
        self.failed_actions.append(&back);
    }

    fn offer_regular_sheet(self: &Rc<Self>, typed_address: &str) {
        let cancel = gtk::Button::with_label(copy::CANCEL_BUTTON);
        let this = Rc::downgrade(self);
        cancel.connect_clicked(move |_| {
            if let Some(this) = this.upgrade() {
                this.close();
            }
        });
        let regular = gtk::Button::with_label(copy::ADD_AS_REGULAR_BUTTON);
        regular.add_css_class("suggested-action");
        let this = Rc::downgrade(self);
        let typed = typed_address.to_owned();
        regular.connect_clicked(move |_| {
            let Some(this) = this.upgrade() else { return };
            this.close();
            crate::ui::servers::present_add(
                &this.ui,
                &Prefill {
                    address: typed.clone(),
                    ..Prefill::default()
                },
            );
        });
        self.failed_actions.append(&cancel);
        self.failed_actions.append(&regular);
    }
}

fn announce(label: &gtk::Label, message: &str) {
    label.announce(message, gtk::AccessibleAnnouncementPriority::Medium);
}

fn page_box(children: &[&gtk::Widget]) -> gtk::Box {
    let page = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(14)
        .margin_top(12)
        .margin_bottom(18)
        .margin_start(18)
        .margin_end(18)
        .build();
    for child in children {
        page.append(*child);
    }
    page
}

fn centered(children: &[&gtk::Widget]) -> gtk::Box {
    let page = page_box(children);
    page.set_spacing(12);
    page.set_halign(gtk::Align::Center);
    page.set_margin_top(28);
    page.set_margin_bottom(28);
    page
}

fn button_row(buttons: &[&gtk::Button]) -> gtk::Box {
    let row = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(8)
        .halign(gtk::Align::End)
        .build();
    for button in buttons {
        row.append(*button);
    }
    row
}

fn heading_label() -> gtk::Label {
    let label = gtk::Label::builder().wrap(true).justify(gtk::Justification::Center).build();
    label.add_css_class("title-2");
    label
}

fn body_label(text: &str) -> gtk::Label {
    let label = gtk::Label::builder()
        .label(text)
        .wrap(true)
        .max_width_chars(44)
        .justify(gtk::Justification::Center)
        .build();
    label.add_css_class("dim-label");
    label
}

fn icon(name: &str, class: &str) -> gtk::Image {
    let image = gtk::Image::from_icon_name(name);
    image.set_pixel_size(48);
    image.add_css_class(class);
    image
}
